namespace Biblio.Core;

public enum CiteStyle { Apa, Harvard, Mla, Chicago, Ieee }

public static class Cite
{
    public static string Label(CiteStyle s) => s switch
    {
        CiteStyle.Apa => "APA 7", CiteStyle.Harvard => "Harvard", CiteStyle.Mla => "MLA 9",
        CiteStyle.Chicago => "Chicago (author-date)", _ => "IEEE",
    };

    static string CompactInitials(string given) => Apa.Initials(given).Replace(" ", "");
    static string Bare(string d) => d.Replace("https://doi.org/", "").Replace("http://dx.doi.org/", "").Trim();
    static string Pages(string p) => p.Replace("-", "–");
    static string End(string s) => Apa.Ending(s);
    static string Headline(string t)
    {
        var c = Apa.Clean(t);
        return (Text_.IsAllUpper(c) && c != c.ToLowerInvariant()) ? Text_.Capitalized(c) : c;
    }
    static string Given(Person p) => Apa.Clean(p.Given);
    static string Family(Person p) => Apa.Clean(p.Family);
    static string LastFirst(Person p) => Given(p).Length == 0 ? Family(p) : $"{Family(p)}, {Given(p)}";
    static string FirstLast(Person p) => Given(p).Length == 0 ? Family(p) : $"{Given(p)} {Family(p)}";
    static bool IsJournal(Ref r) => r.Type == "journal-article" && Apa.Clean(r.Container).Length > 0;
    static bool IsChapter(Ref r) => (r.Type == "book-chapter" || r.Type == "chapter") && Apa.Clean(r.Container).Length > 0;
    static string Join(params string[] parts) => string.Join(" ", parts.Where(p => p.Length > 0)).Replace("  ", " ");
    static string Title(Ref r) => Apa.FixTitle(Apa.Clean(r.Title), r.Authors.Select(a => a.Family));

    public static string Format(Ref r, CiteStyle style) => style switch
    {
        CiteStyle.Apa => Apa.Format(r),
        CiteStyle.Harvard => Harvard(r),
        CiteStyle.Mla => Mla(r),
        CiteStyle.Chicago => Chicago(r),
        _ => Ieee(r),
    };

    static string Harvard(Ref r)
    {
        var people = r.Authors.Select(p => { var i = CompactInitials(p.Given); return i.Length == 0 ? Family(p) : $"{Family(p)}, {i}"; }).ToList();
        string a = people.Count switch
        {
            0 => "", 1 => people[0],
            2 or 3 => string.Join(", ", people.Take(people.Count - 1)) + " and " + people[^1],
            _ => people[0] + " et al.",
        };
        var year = $"({(r.Year?.ToString() ?? "no date")})";
        var title = Title(r);
        var doi = r.Doi.Length == 0 ? "" : $"doi: {Bare(r.Doi)}";
        if (IsJournal(r))
        {
            var src = $"*{Apa.JournalCase(r.Container)}*";
            if (r.Volume.Length > 0) src += $", {r.Volume}" + (r.Issue.Length == 0 ? "" : $"({r.Issue})");
            if (r.Pages.Length > 0) src += $", pp. {Pages(r.Pages)}";
            return Join(a, year, $"‘{title}’,", src + ".", doi);
        }
        if (IsChapter(r))
        {
            var eds = r.Editors.Select(p => { var i = CompactInitials(p.Given); return i.Length == 0 ? Family(p) : $"{i} {Family(p)}"; }).ToList();
            var s = Join(a, year, $"‘{title}’, in");
            if (eds.Count > 0) s += " " + string.Join(", ", eds) + (eds.Count == 1 ? " (ed.)" : " (eds.)");
            s += $" *{Apa.Clean(r.Container)}*.";
            if (Apa.Clean(r.Publisher).Length > 0) s += $" {Apa.Clean(r.Publisher)}" + (r.Pages.Length == 0 ? "." : $", pp. {Pages(r.Pages)}.");
            return Join(s, doi);
        }
        return Join(a, year, $"*{End(title)}*", Apa.Clean(r.Publisher).Length == 0 ? "" : End(Apa.Clean(r.Publisher)), doi);
    }

    static string Mla(Ref r)
    {
        string a = r.Authors.Count switch
        {
            0 => "", 1 => LastFirst(r.Authors[0]),
            2 => LastFirst(r.Authors[0]) + ", and " + FirstLast(r.Authors[1]),
            _ => LastFirst(r.Authors[0]) + ", et al",
        };
        var title = Headline(r.Title);
        var doi = r.Doi.Length == 0 ? "" : "https://doi.org/" + Bare(r.Doi);
        var year = r.Year?.ToString() ?? "n.d.";
        var head = a.Length == 0 ? "" : End(a);
        if (IsJournal(r))
        {
            var src = $"*{Apa.JournalCase(r.Container)}*";
            if (r.Volume.Length > 0) src += $", vol. {r.Volume}";
            if (r.Issue.Length > 0) src += $", no. {r.Issue}";
            src += $", {year}";
            if (r.Pages.Length > 0) src += $", pp. {Pages(r.Pages)}";
            return Join(head, $"“{End(title)}”", src + ".", doi.Length == 0 ? "" : doi + ".");
        }
        if (IsChapter(r))
        {
            var src = $"*{Apa.Clean(r.Container)}*";
            if (r.Editors.Count > 0) src += ", edited by " + string.Join(r.Editors.Count > 2 ? ", " : " and ", r.Editors.Select(FirstLast));
            if (Apa.Clean(r.Publisher).Length > 0) src += $", {Apa.Clean(r.Publisher)}";
            src += $", {year}";
            if (r.Pages.Length > 0) src += $", pp. {Pages(r.Pages)}";
            return Join(head, $"“{End(title)}”", src + ".", doi.Length == 0 ? "" : doi + ".");
        }
        var pub = Apa.Clean(r.Publisher);
        return Join(head, $"*{End(title)}*", pub.Length == 0 ? $"{year}." : $"{pub}, {year}.", doi.Length == 0 ? "" : doi + ".");
    }

    static string Chicago(Ref r)
    {
        var all = r.Authors;
        string a = "";
        if (all.Count > 10) a = string.Join(", ", new[] { LastFirst(all[0]) }.Concat(all.Skip(1).Take(6).Select(FirstLast))) + ", et al.";
        else if (all.Count == 1) a = LastFirst(all[0]);
        else if (all.Count == 2) a = LastFirst(all[0]) + " and " + FirstLast(all[1]);
        else if (all.Count > 2) a = string.Join(", ", new[] { LastFirst(all[0]) }.Concat(all.Skip(1).Take(all.Count - 2).Select(FirstLast))) + ", and " + FirstLast(all[^1]);
        var year = r.Year?.ToString() ?? "n.d.";
        var title = Headline(r.Title);
        var doi = r.Doi.Length == 0 ? "" : "https://doi.org/" + Bare(r.Doi) + ".";
        var head = a.Length == 0 ? "" : End(a);
        if (IsJournal(r))
        {
            var src = $"*{Apa.JournalCase(r.Container)}*";
            if (r.Volume.Length > 0) src += $" {r.Volume}";
            if (r.Issue.Length > 0) src += $" ({r.Issue})";
            if (r.Pages.Length > 0) src += $": {Pages(r.Pages)}";
            return Join(head, $"{year}.", $"“{End(title)}”", src + ".", doi);
        }
        if (IsChapter(r))
        {
            var src = $"In *{Apa.Clean(r.Container)}*";
            if (r.Editors.Count > 0) src += ", edited by " + string.Join(r.Editors.Count > 2 ? ", " : " and ", r.Editors.Select(FirstLast));
            if (r.Pages.Length > 0) src += $", {Pages(r.Pages)}";
            return Join(head, $"{year}.", $"“{End(title)}”", src + ".", Apa.Clean(r.Publisher).Length == 0 ? "" : End(Apa.Clean(r.Publisher)), doi);
        }
        return Join(head, $"{year}.", $"*{End(title)}*", Apa.Clean(r.Publisher).Length == 0 ? "" : End(Apa.Clean(r.Publisher)), doi);
    }

    static string Ieee(Ref r)
    {
        var names = r.Authors.Select(p => { var i = Apa.Initials(p.Given); return i.Length == 0 ? Family(p) : $"{i} {Family(p)}"; }).ToList();
        string a = names.Count switch
        {
            0 => "", 1 => names[0], 2 => names[0] + " and " + names[1],
            <= 6 => string.Join(", ", names.Take(names.Count - 1)) + ", and " + names[^1],
            _ => names[0] + " et al.",
        };
        var year = r.Year?.ToString() ?? "n.d.";
        var title = Headline(r.Title);
        var doi = r.Doi.Length == 0 ? "" : $"doi: {Bare(r.Doi)}.";
        var lead = a.Length == 0 ? "" : a + ",";
        if (IsJournal(r))
        {
            var src = $"*{Apa.JournalCase(r.Container)}*";
            if (r.Volume.Length > 0) src += $", vol. {r.Volume}";
            if (r.Issue.Length > 0) src += $", no. {r.Issue}";
            if (r.Pages.Length > 0) src += $", pp. {Pages(r.Pages)}";
            src += $", {year}";
            return Join(lead, $"“{title},”", src + (doi.Length == 0 ? "." : ","), doi);
        }
        if (IsChapter(r))
        {
            var src = $"in *{Apa.Clean(r.Container)}*";
            if (r.Editors.Count > 0)
                src += ", " + string.Join(", ", r.Editors.Select(p => { var i = Apa.Initials(p.Given); return i.Length == 0 ? Family(p) : $"{i} {Family(p)}"; })) + (r.Editors.Count == 1 ? ", Ed." : ", Eds.");
            if (Apa.Clean(r.Publisher).Length > 0) src += $". {Apa.Clean(r.Publisher)}";
            src += $", {year}";
            if (r.Pages.Length > 0) src += $", pp. {Pages(r.Pages)}";
            return Join(lead, $"“{title},”", src + (doi.Length == 0 ? "." : ","), doi);
        }
        var pub = Apa.Clean(r.Publisher);
        return Join(lead, $"*{title}*.", pub.Length == 0 ? $"{year}." : $"{pub}, {year}.", doi);
    }

    public static string Minimal(IList<string> authors, int? year)
    {
        var a = authors.Count <= 2 ? string.Join(" & ", authors) : authors[0] + " et al.";
        return $"{a} ({(year?.ToString() ?? "n.d.")}). [Incomplete reference: title and publication details not found]";
    }
}
