using Biblio.Core;

// Kullanım: biblio-cli [--dry-run] [--evaluate] [--apa] [--guess] [--template "{Author} - {Year}"] [--style apa|harvard|mla|chicago|ieee] DOSYA_veya_KLASOR...
var args_ = args.ToList();
string? Take(string name)
{
    int i = args_.IndexOf(name);
    if (i < 0 || i + 1 >= args_.Count) return null;
    var v = args_[i + 1]; args_.RemoveRange(i, 2); return v;
}
var t = Take("--template"); if (t != null) Engine.Naming.Template = t;
var tm = Take("--title-max"); if (tm != null) Engine.Naming.TitleMax = int.Parse(tm);
var st = Take("--style"); if (st != null) Engine.Style = Enum.Parse<CiteStyle>(st, true);
bool dry = args_.Contains("--dry-run"), eval = args_.Contains("--evaluate"), apa = args_.Contains("--apa");
if (eval) Engine.UseFilename = false;
if (args_.Contains("--guess")) Engine.GuessEnabled = true;
var parseArg = Take("--parse");
if (parseArg != null)
{
    var pr = RefParse.Parse(parseArg);
    Console.WriteLine(pr == null ? "null" : System.Text.Json.JsonSerializer.Serialize(pr, new System.Text.Json.JsonSerializerOptions { IncludeFields = true, WriteIndented = false }));
    if (pr != null)
    {
        var people = RefParse.ParsePeople(pr.Authors);
        var rf = new Ref { Authors = people, Year = int.TryParse(pr.Year, out var yy) ? yy : null, Title = pr.Title, Container = pr.Container, Volume = pr.Volume, Issue = pr.Issue, Pages = pr.Pages, Doi = pr.Doi, Publisher = pr.Publisher, Type = pr.Type };
        foreach (CiteStyle cs in Enum.GetValues<CiteStyle>()) Console.WriteLine($"{cs}: {Cite.Format(rf, cs)}");
        Console.WriteLine("name: " + Namer.Render(new NameFields { Authors = people.Select(x => x.Family).ToList(), Year = rf.Year }, Engine.Naming));
        var docxOut = Take("--docx-out"); if (docxOut != null) File.WriteAllBytes(docxOut, Docx.Build(new[] { (Cite.Format(rf, CiteStyle.Apa), false), ("Doe (n.d.). [Incomplete reference]", true) }));
    }
    return;
}
var refsArg = Take("--refs");
if (refsArg != null)
{
    var dl = Take("--download");
    var list = Bibliography.Entries(refsArg);
    Console.WriteLine($"{list.Count} entries");
    foreach (var e in list)
    {
        try
        {
            var r = await Bibliography.Resolve(e);
            if (r == null) { Console.WriteLine($"?? {e[..Math.Min(70, e.Length)]}"); continue; }
            Console.WriteLine($"OK {r.Title} | {r.Doi} | landing={r.Landing} | openAlexDown={r.OpenAlexDown}");
            foreach (var v in r.Versions)
            {
                Console.WriteLine($"   - {v.Label}: {v.Pdf}");
                if (dl != null && v.Pdf != null) Console.WriteLine("     downloaded: " + (await Bibliography.DownloadPdf(v.Pdf, dl, "ref-test") ?? "no"));
            }
        }
        catch (Exception ex) { Console.WriteLine("!! " + ex.Message + " " + Engine.LastIssue); }
    }
    return;
}
var files = new List<string>();
foreach (var p in args_.Where(a => !a.StartsWith("--")))
{
    var full = Path.GetFullPath(p.Replace("~", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)));
    if (Directory.Exists(full)) files.AddRange(Directory.GetFiles(full, "*.pdf").Where(f => !Path.GetFileName(f).StartsWith("~$")).OrderBy(f => f, StringComparer.Ordinal));
    else files.Add(full);
}
var proc = new Processor();
var sem = new SemaphoreSlim(4);
var results = new Outcome[files.Count];
await Task.WhenAll(files.Select(async (f, i) =>
{
    await sem.WaitAsync();
    try { results[i] = await proc.Process(f, dry, eval); } finally { sem.Release(); }
}));
foreach (var o in results)
{
    var n = Path.GetFileName(o.Path);
    switch (o.Kind)
    {
        case OutcomeKind.Renamed:
            Console.WriteLine($"{n}\n   -> {Path.GetFileName(o.To!)}  [{o.Note}]");
            if (apa) Console.WriteLine($"   REF: {o.Entry!.Render(Engine.Style)}");
            break;
        case OutcomeKind.Flagged: Console.WriteLine($"!! {n} -> {Path.GetFileName(o.To!)}: {o.Note}"); break;
        case OutcomeKind.Skipped: Console.WriteLine($"-- {n}: {o.Note}"); break;
        case OutcomeKind.Pending: Console.WriteLine($"?? {n}: {o.Note}"); break;
        case OutcomeKind.Kunye: Console.WriteLine($"REF {n}\n   {o.Entry!.Render(Engine.Style)}"); break;
    }
}
