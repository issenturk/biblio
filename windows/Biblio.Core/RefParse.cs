using System.Text.RegularExpressions;

namespace Biblio.Core;

/// <summary>Elle yazılmış APA benzeri künyeyi alanlara ayırır (yerel). Örn: "Becker, G. S. (1965). A Theory of the Allocation of Time. The economic journal, 75(299), 493-517"</summary>
public static class RefParse
{
    public class Parsed
    {
        public string Authors = "", Year = "", Type = "", Title = "", Container = "", Volume = "", Issue = "", Pages = "", Doi = "", Publisher = "";
    }

    static string? Rx(string p, string s, int g = 0)
    {
        var m = Regex.Match(s, p, RegexOptions.IgnoreCase);
        return m.Success && m.Groups[g].Success ? m.Groups[g].Value : null;
    }

    public static Parsed? Parse(string raw)
    {
        var s = raw.Replace("*", "").Replace("\n", " ").Replace("–", "-").Replace("—", "-").Trim();
        if (s.Length == 0) return null;
        var o = new Parsed();

        var d = Rx(@"10\.\d{4,9}/[^\s""<>]+", s);
        if (d != null)
        {
            o.Doi = d.Trim(".,;)]}".ToCharArray());
            s = s.Replace(d, "");
            s = Regex.Replace(s, @"(https?://(dx\.)?doi\.org/?|doi:\s*)", "", RegexOptions.IgnoreCase);
        }
        s = s.Trim(" .,;".ToCharArray());

        string authorPart, rest;
        var m = Regex.Match(s, @"\(\s*((?:1[0-9]|20)\d{2})[a-z]?\s*\)|\(\s*n\.d\.\s*\)");
        if (m.Success)
        {
            var y = Rx(@"\d{4}", m.Value);
            if (y != null) o.Year = y;
            authorPart = s[..m.Index]; rest = s[(m.Index + m.Length)..];
        }
        else
        {
            var y = Rx(@"\b(1[5-9]\d{2}|20\d{2})\b", s, 1);
            if (y == null) return null;
            int idx = s.IndexOf(y, StringComparison.Ordinal);
            o.Year = y;
            authorPart = s[..idx]; rest = s[(idx + y.Length)..];
        }

        o.Authors = Authors(authorPart);
        rest = rest.Trim(" .,;)(-".ToCharArray());
        if (rest.Length == 0) return o;

        // Başlık: ilk cümle sonu (tek harf+nokta kısaltmaları cümle sonu sayılmaz)
        int cut = -1;
        for (int i = 0; i < rest.Length; i++)
        {
            if (!".?!".Contains(rest[i])) continue;
            var next = i + 1 < rest.Length ? rest[i + 1] : ' ';
            if (next != ' ') continue;
            if (rest[i] == '.' && i >= 1 && char.IsLetter(rest[i - 1]) && (i < 2 || !char.IsLetter(rest[i - 2])) && char.IsUpper(rest[i - 1])) continue;
            cut = i; break;
        }
        string title = rest, after = "";
        if (cut >= 0)
        {
            title = rest[..(rest[cut] == '.' ? cut : cut + 1)];
            after = rest[(cut + 1)..];
        }
        o.Title = title.Trim();
        after = after.Trim(" .,;".ToCharArray());
        if (after.Length == 0) return o;

        var j = Rx(@"^(.+?),\s*(\d+)\s*(?:\(\s*([^)]*?)\s*\))?\s*,\s*([A-Za-z]?\d[\w-]*(?:\s*-\s*[A-Za-z]?\d[\w]*)?)", after);
        if (!string.IsNullOrEmpty(j))
        {
            o.Container = Rx(@"^(.+?),\s*\d+", j, 1) ?? "";
            o.Volume = Rx(@",\s*(\d+)\s*(?:\(|,)", j, 1) ?? "";
            o.Issue = Rx(@"\(\s*([^)]*?)\s*\)", j, 1) ?? "";
            o.Pages = (Rx(@"\)?\s*,\s*([A-Za-z]?\d[\w-]*(?:\s*-\s*[A-Za-z]?\d[\w]*)?)\s*$", j, 1) ?? "").Replace(" ", "");
            o.Type = "journal-article";
            return o;
        }
        j = Rx(@"^(.+?),\s*(\d+)\s*(?:\(\s*([^)]*?)\s*\))?\s*$", after);
        if (j != null)
        {
            o.Container = Rx(@"^(.+?),\s*\d+", j, 1) ?? "";
            o.Volume = Rx(@",\s*(\d+)", j, 1) ?? "";
            o.Issue = Rx(@"\(\s*([^)]*?)\s*\)", j, 1) ?? "";
            o.Type = "journal-article";
            return o;
        }
        if (after.StartsWith("in ", StringComparison.OrdinalIgnoreCase))
        {
            var body = after[3..];
            var t = Rx(@"\((?:eds?\.?)\)\s*,?\s*(.+?)\s*(?:\(\s*(?:pp?\.)\s*([\d-]+)\s*\))?\s*(?:\.\s*(.*))?$", body, 1);
            if (t != null) o.Container = t;
            o.Pages = (Rx(@"pp?\.\s*([\d]+\s*-\s*[\d]+)", body, 1) ?? "").Replace(" ", "");
            o.Publisher = Rx(@"\)\.\s*([^.]+)\.?\s*$", body, 1) ?? "";
            o.Type = "book-chapter";
            return o;
        }
        if (Rx(@"working paper|discussion paper|technical report|report|nber|ssrn|preprint", after) != null)
        {
            o.Publisher = after.Trim(" .".ToCharArray());
            o.Type = "report";
            return o;
        }
        o.Publisher = after.Trim(" .".ToCharArray());
        o.Type = "book";
        return o;
    }

    public static string Authors(string part)
    {
        var a = part.Replace("&", ",").Replace("…", ",").Replace("...", ",");
        a = Regex.Replace(a, @"\s+\band\b\s+", ", ", RegexOptions.IgnoreCase);
        a = Regex.Replace(a, @"\bet al\.?", "", RegexOptions.IgnoreCase);
        var toks = a.Split(',').Select(x => x.Trim()).Where(x => x.Length > 0).ToList();
        if (toks.Count == 0) return "";
        bool initialsStyle = toks.Count >= 2 && toks.Where((t, i) => i % 2 == 1 && LooksGiven(t)).Any();
        if (!initialsStyle) return string.Join("\n", toks);
        var lines = new List<string>();
        int k = 0;
        while (k < toks.Count)
        {
            if (k + 1 < toks.Count && LooksGiven(toks[k + 1])) { lines.Add($"{toks[k]}, {toks[k + 1]}"); k += 2; }
            else { lines.Add(toks[k]); k++; }
        }
        return string.Join("\n", lines);
    }

    static bool LooksGiven(string s) =>
        Regex.IsMatch(s, @"^([A-Z][A-Za-zÀ-ſ'\-]*\.?\s*[-]?\s*)+$") && s.Length <= 40 && (s.Contains('.') || !s.Contains(' '));

    /// <summary>Çok satırlı yazar kutusundan kişileri okur ("Soyad, Ad" ya da "Ad Soyad").</summary>
    public static List<Person> ParsePeople(string s)
    {
        var outp = new List<Person>();
        foreach (var raw in s.Split(new[] { '\n', ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            int c = line.IndexOf(',');
            outp.Add(c >= 0 ? new Person(line[..c].Trim(), line[(c + 1)..].Trim()) : Engine.SplitName(line));
        }
        return outp;
    }
}
