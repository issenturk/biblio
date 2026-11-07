using System.Text.RegularExpressions;

namespace Biblio.Core;

public static class Apa
{
    /// <summary>Büyük harfle kalması gereken yaygın sözcükler (başlığı cümle düzenine çevirirken korunur).</summary>
    static readonly HashSet<string> Keep = new()
    {
        "English","German","French","Italian","Spanish","Turkish","Chinese","Japanese","Indian","Russian",
        "European","American","African","Asian","Latin","Nordic","British","Canadian","Australian","Europe","America","Africa",
        "Asia","China","India","Turkey","Germany","France","Italy","Spain","Japan","Brazil","Mexico","Canada","Australia",
        "Korea","Korean","Poland","Polish","Dutch","Netherlands","Greece","Greek","Thailand",
        "Romania","Hungary","Portugal","Sweden","Finland","Denmark","Norway","Pacific","Atlantic",
        "Marxist","Keynesian","Bayesian","Gaussian","Nobel","Covid-19","Africa","United","States","Kingdom","Union","World","War",
        "Bank","Fed","Federal","Reserve","Indonesia","Pakistan","Egypt","Iran","Iraq","Israel","Africa","Ottoman","Soviet","Nordic",
        "Chinese","Beijing","London","Paris","Berlin","Istanbul","Ankara","Tokyo","Washington","California","Texas","Michigan",
    };

    public static string Clean(string s)
    {
        var t = Regex.Replace(s, "<[^>]+>", "");
        foreach (var (a, b) in new[] { ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'") }) t = t.Replace(a, b);
        t = t.Trim("☆*†‡ \n\t".ToCharArray());
        return string.Join(" ", t.Split(new[] { ' ', '\n', '\t' }, StringSplitOptions.RemoveEmptyEntries));
    }

    public static string Initials(string given)
    {
        var parts = given.Replace(".", ". ").Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var outp = new List<string>();
        foreach (var p in parts)
        {
            if (p.Contains('-'))
                outp.Add(string.Join("-", p.Split('-', StringSplitOptions.RemoveEmptyEntries).Select(x => char.ToUpperInvariant(x[0]) + ".")));
            else if (char.IsLetter(p[0])) outp.Add(char.ToUpperInvariant(p[0]) + ".");
        }
        return string.Join(" ", outp);
    }

    public static string Name(Person p)
    {
        var i = Initials(p.Given);
        return i.Length == 0 ? Clean(p.Family) : $"{Clean(p.Family)}, {i}";
    }

    public static string AuthorList(IList<Person> ps)
    {
        var n = ps.Select(Name).ToList();
        return n.Count switch
        {
            0 => "",
            1 => n[0],
            <= 20 => string.Join(", ", n.Take(n.Count - 1)) + ", & " + n[^1],
            _ => string.Join(", ", n.Take(19)) + ", . . . " + n[^1],
        };
    }

    static string LowerFirstLetter(string w)
    {
        int i = w.ToList().FindIndex(char.IsLetter);
        if (i < 0) return w;
        return w[..i] + char.ToLowerInvariant(w[i]) + w[(i + 1)..];
    }

    /// <summary>Başlık Title Case ise APA'nın cümle düzenine çevirir. Windows'ta kişi/yer adı tanıyıcı yok:
    /// büyük harfli yaygın özel adlar, kısaltmalar ve (varsa) yazar soyadları korunur.</summary>
    public static string SentenceCase(string t, IEnumerable<string>? protect = null)
    {
        var words = t.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var content = words.Where(w => w.Count(char.IsLetter) > 3).ToList();
        if (content.Count < 3) return t;
        int capped = content.Count(w => char.IsUpper(w.First(char.IsLetter)));
        if ((double)capped / content.Count < 0.6) return t;   // zaten cümle düzeninde

        var prot = new HashSet<string>((protect ?? Array.Empty<string>()).Select(x => x.Trim()));
        var res = new List<string>();
        for (int i = 0; i < words.Length; i++)
        {
            var w = words[i];
            int letters = w.Count(char.IsLetter);
            bool afterBreak = i == 0 || new[] { ":", "?", "!", ".", "–", "—" }.Any(s => words[i - 1].EndsWith(s)) || new[] { "–", "—", "-" }.Contains(words[i - 1]);
            var core = w.Trim(".,;:!?()[]\"'“”‘’".ToCharArray());
            bool innerCaps = w.Skip(1).Any(char.IsUpper) && w.Any(char.IsLower);
            if (afterBreak || prot.Contains(core) || Keep.Contains(core) || (letters >= 2 && Text_.IsAllUpper(w)) || w.Any(char.IsDigit) || innerCaps
                || (letters == 1 && char.IsUpper(w.First(char.IsLetter)) && words.Length > 1 && w.First(char.IsLetter) == 'I'))
            {
                if (i > 0 && afterBreak)
                {
                    int f = w.ToList().FindIndex(char.IsLetter);
                    res.Add(f < 0 ? w : w[..f] + char.ToUpperInvariant(w[f]) + w[(f + 1)..]);
                }
                else res.Add(w);
            }
            else
            {
                var parts = w.Split('-');
                res.Add(string.Join("-", parts.Select((p, j) => (j > 0 && Text_.IsAllUpper(p) && p.Length > 1) ? p : LowerFirstLetter(p))));
            }
        }
        return string.Join(" ", res);
    }

    public static string FixTitle(string t, IEnumerable<string>? protect = null)
    {
        var x = SentenceCase(t, protect).Replace("?:", "?").Replace("!:", "!");
        x = Regex.Replace(x, @"(:\s+)(\p{Ll})", m => m.Groups[1].Value + m.Groups[2].Value.ToUpperInvariant());
        return x;
    }

    public static string JournalCase(string s)
    {
        var c = Clean(s);
        return (c == c.ToUpperInvariant() || c == c.ToLowerInvariant()) ? Text_.Capitalized(c) : c;
    }

    public static string DoiUrl(string d)
    {
        var t = d.Replace("https://doi.org/", "").Replace("http://dx.doi.org/", "").Trim();
        return t.Length == 0 ? "" : "https://doi.org/" + t;
    }

    public static string Ending(string s) => (s.Length == 0 || ".?!".Contains(s[^1])) ? s : s + ".";

    static IEnumerable<string> Surnames(Ref r) => r.Authors.Select(a => a.Family);

    public static string Format(Ref r)
    {
        var prot = Surnames(r).Concat(r.Editors.Select(a => a.Family)).ToList();
        var authors = AuthorList(r.Authors);
        var title = Clean(r.Title);
        var date = $"({(r.Year?.ToString() ?? "n.d.")}).";
        var doi = DoiUrl(r.Doi);
        bool isJournal = r.Type == "journal-article" && Clean(r.Container).Length > 0;
        bool isChapter = (r.Type == "book-chapter" || r.Type == "chapter") && Clean(r.Container).Length > 0;
        var parts = new List<string>();
        if (authors.Length > 0) parts.Add(Ending(authors));

        if (isJournal)
        {
            if (authors.Length == 0) { parts.Add(Ending(FixTitle(title, prot))); parts.Add(date); } else { parts.Add(date); parts.Add(Ending(FixTitle(title, prot))); }
            var src = $"*{JournalCase(r.Container)}*";
            if (r.Volume.Length > 0) src += $", *{r.Volume}*";
            if (r.Issue.Length > 0) src += $"({r.Issue})";
            if (r.Pages.Length > 0) src += ", " + r.Pages.Replace("-", "–");
            parts.Add(src + ".");
        }
        else if (isChapter)
        {
            parts.Add(date);
            parts.Add(Ending(FixTitle(title, prot)));
            var eds = r.Editors.Select(p => { var i = Initials(p.Given); return i.Length == 0 ? Clean(p.Family) : $"{i} {Clean(p.Family)}"; }).ToList();
            var inPart = "In ";
            if (eds.Count > 0)
                inPart += (eds.Count == 1 ? eds[0] : string.Join(", ", eds.Take(eds.Count - 1)) + (eds.Count > 2 ? "," : "") + " & " + eds[^1]) + (eds.Count == 1 ? " (Ed.), " : " (Eds.), ");
            inPart += $"*{Clean(r.Container)}*";
            if (r.Pages.Length > 0) inPart += $" (pp. {r.Pages.Replace("-", "–")})";
            parts.Add(inPart + ".");
            if (Clean(r.Publisher).Length > 0) parts.Add(Ending(Clean(r.Publisher)));
        }
        else
        {
            if (authors.Length == 0) { parts.Add($"*{Ending(FixTitle(title, prot))}*"); parts.Add(date); } else { parts.Add(date); parts.Add($"*{Ending(FixTitle(title, prot))}*"); }
            if (Clean(r.Publisher).Length > 0) parts.Add(Ending(Clean(r.Publisher)));
        }
        if (doi.Length > 0) parts.Add(doi);
        return string.Join(" ", parts).Replace("  ", " ");
    }
}
