using System.Text.RegularExpressions;

namespace Biblio.Core;

public class NamingPrefs
{
    public string Template { get; set; } = "{Author} - {Year}";
    public int TitleMax { get; set; } = 60;
    public int MaxAuthors { get; set; } = 2;
    public string AndWord { get; set; } = "&";
    public string EtAl { get; set; } = "et al";
    public bool KeepAccents { get; set; } = false;
}

public class NameFields
{
    public List<string> Authors { get; set; } = new();
    public int? Year { get; set; }
    public string Title { get; set; } = "";
    public string Journal { get; set; } = "";
    public string Doi { get; set; } = "";
}

public static class Namer
{
    public static readonly (string Id, string Template, string En, string Tr)[] Presets =
    {
        ("author-year", "{Author} - {Year}", "Author - Year", "Yazar - Yıl"),
        ("author-year-paren", "{Author} ({Year})", "Author (Year)", "Yazar (Yıl)"),
        ("author-year-title", "{Author} - {Year} - {Title}", "Author - Year - Title", "Yazar - Yıl - Başlık"),
        ("year-author-title", "{Year} - {Author} - {Title}", "Year - Author - Title", "Yıl - Yazar - Başlık"),
        ("author-year-journal", "{Author} - {Year} - {Journal}", "Author - Year - Journal", "Yazar - Yıl - Dergi"),
        ("author-title", "{Author} - {Title}", "Author - Title", "Yazar - Başlık"),
        ("underscore", "{FirstAuthor}_{Year}", "FirstAuthor_Year", "İlkYazar_Yıl"),
    };

    public const string DefaultTemplate = "{Author} - {Year}";
    public static readonly string[] Tokens = { "{Author}", "{FirstAuthor}", "{Year}", "{Title}", "{Journal}", "{DOI}" };

    public static bool TemplateIsUsable(string t)
    {
        var low = t.ToLowerInvariant();
        return low.Contains("{author}") || low.Contains("{firstauthor}") || low.Contains("{title}");
    }

    const string Separators = " -_–—,.:;";

    static string CapitalizeIfShouting(string s) => (s == s.ToUpperInvariant() && s != s.ToLowerInvariant()) ? Text_.Capitalized(s) : s;

    static string Clean(string s, bool keepAccents)
    {
        var t = Apa.Clean(s);
        if (keepAccents)
        {
            t = t.Replace(":", " -");
            t = new string(t.Where(c => !"/\\*?\"<>|".Contains(c) && !char.IsControl(c)).ToArray());
            return string.Join(" ", t.Split(' ', StringSplitOptions.RemoveEmptyEntries));
        }
        return Text_.Fold(t);
    }

    static string Truncate(string s, int max)
    {
        if (s.Length <= max || max <= 0) return s;
        var cut = s[..max];
        int sp = cut.LastIndexOf(' ');
        if (sp >= max / 2) cut = cut[..sp];
        return cut.Trim(Separators.ToCharArray());
    }

    public static string AuthorString(IList<string> authors, NamingPrefs prefs)
    {
        var fam = authors.Select(a => CapitalizeIfShouting(Clean(a, prefs.KeepAccents))).Where(a => a.Length > 0).ToList();
        if (fam.Count == 0) return "";
        int limit = Math.Max(1, prefs.MaxAuthors);
        if (fam.Count > limit) return $"{fam[0]} {prefs.EtAl}";
        if (fam.Count == 1) return fam[0];
        if (prefs.AndWord == ",") return string.Join(", ", fam);
        if (fam.Count == 2) return $"{fam[0]} {prefs.AndWord} {fam[1]}";
        return string.Join(", ", fam.Take(fam.Count - 1)) + $" {prefs.AndWord} " + fam[^1];
    }

    public static string Render(NameFields f, NamingPrefs prefs, string suffix = "")
    {
        var template = prefs.Template.Trim();
        if (!TemplateIsUsable(template)) template = DefaultTemplate;
        bool hasYear = template.ToLowerInvariant().Contains("{year}");

        string Value(string token) => token.ToLowerInvariant() switch
        {
            "author" => AuthorString(f.Authors, prefs),
            "firstauthor" => AuthorString(f.Authors.Take(1).ToList(), prefs),
            "year" => (f.Year?.ToString() ?? "xxxx") + suffix,
            "title" => Truncate(Clean(f.Title, prefs.KeepAccents), prefs.TitleMax),
            "journal" => Truncate(Clean(f.Journal, prefs.KeepAccents), prefs.TitleMax),
            "doi" => Clean(f.Doi.Replace("/", "_"), true).Replace(" ", ""),
            _ => "",
        };

        var outp = Regex.Replace(template, @"\{(\w+)\}", m => Value(m.Groups[1].Value));
        if (!hasYear) outp += suffix;
        outp = Regex.Replace(outp, @"\(\s*\)|\[\s*\]", "");
        outp = Regex.Replace(outp, @"\s{2,}", " ");
        outp = Regex.Replace(outp, @"(\s*[-_–—,]\s*){2,}", " - ");
        outp = outp.Trim(Separators.ToCharArray());
        while (outp.StartsWith('.')) outp = outp[1..];
        if (outp.Length > 200) outp = outp[..200].Trim(Separators.ToCharArray());
        // Windows: dosya adında yasak karakterler ve sondaki nokta/boşluk
        outp = new string(outp.Where(c => !"<>:\"/\\|?*".Contains(c)).ToArray()).TrimEnd('.', ' ');
        return outp.Length == 0 ? "Untitled" : outp;
    }
}
