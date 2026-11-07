using System.Globalization;
using System.Net;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Biblio.Core;

/// <summary>PDF'ten alınan sayfa metni ve (isteğe bağlı) OCR sağlayıcısı.</summary>
public interface IOcr { string OcrPage(string pdfPath, int pageIndex); }

public static class Engine
{
    public static int CurrentYear => DateTime.Now.Year;

    // MARK: Ayarlar
    public static string? OpenAlexKey;
    public static bool OnlineEnabled = true;
    public static bool UseFilename = true;
    public static bool GuessEnabled = false;
    public static DateTime OpenAlexCooldownUntil = DateTime.MinValue;
    public static NamingPrefs Naming = new();
    public static CiteStyle Style = CiteStyle.Apa;
    public static string LastIssue = "";
    public static IOcr? Ocr;

    // MARK: Metin karşılaştırma
    public static bool TitleInText(string title, string text)
    {
        var tt = Text_.Tokens(title);
        if (tt.Count == 0) return false;
        return (double)tt.Intersect(Text_.Tokens(text)).Count() / tt.Count >= 0.6;
    }

    public static bool ContainsPhrase(string text, string title)
    {
        var t = Text_.Norm(title);
        if (t.Length < 8) return false;
        if (Text_.Norm(text).Contains(t)) return true;
        var st = t.Replace(" ", "");
        return st.Length >= 12 && Text_.Squash(text).Contains(st);
    }

    static readonly string[] SkipLines = { "foreword", "preface", "editor", "edited by", "supervisor", "advisor", "danışman", "translated", "önsöz" };

    public static bool AuthorOnPage(IEnumerable<string> authors, string text)
    {
        var kept = string.Join("\n", text.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Where(l => !SkipLines.Any(s => l.ToLowerInvariant().Contains(s))));
        var st = Text_.Squash(kept);
        return authors.Any(a => { var f = Text_.Squash(a); return f.Length >= 3 && st.Contains(f); });
    }

    // MARK: PDF okuma
    public static PageData Read(string path)
    {
        var name = Flag.Strip(Path.GetFileName(path));
        var data = new PageData { Filename = name };
        try
        {
            using var doc = UglyToad.PdfPig.PdfDocument.Open(path, new UglyToad.PdfPig.ParsingOptions { UseLenientParsing = true, SkipMissingFonts = true, Password = "" });
            int n = Math.Min(2, doc.NumberOfPages);
            for (int i = 1; i <= n; i++)
            {
                string t;
                try { t = UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor.ContentOrderTextExtractor.GetText(doc.GetPage(i)); }
                catch { try { t = doc.GetPage(i).Text; } catch { t = ""; } }
                data.Pages.Add(t);
            }
            data.MetaAuthor = doc.Information?.Author;
            if (string.Concat(data.Pages).Trim().Length < 80 && Ocr != null)
            {
                data.Pages = Enumerable.Range(0, n).Select(i => { try { return Ocr.OcrPage(path, i); } catch { return ""; } }).ToList();
                data.Ocr = true;
            }
        }
        catch { }
        return data;
    }

    // MARK: Ağ
    static readonly HttpClient Http = MakeClient();
    static HttpClient MakeClient()
    {
        var c = new HttpClient(new HttpClientHandler { AutomaticDecompression = DecompressionMethods.All }) { Timeout = TimeSpan.FromSeconds(20) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("Biblio/1.0");
        return c;
    }

    // Crossref/doi.org'a saniyede en fazla ~5 istek (aynı anda 4 dosya işlense bile 429 yememek için)
    static readonly SemaphoreSlim gateCr = new(1, 1);
    static DateTime nextCr = DateTime.MinValue;
    static async Task Throttle(bool openAlex)
    {
        if (openAlex) return;
        await gateCr.WaitAsync();
        try
        {
            var wait = nextCr - DateTime.UtcNow;
            if (wait > TimeSpan.Zero) await Task.Delay(wait);
            nextCr = DateTime.UtcNow.AddMilliseconds(220);
        }
        finally { gateCr.Release(); }
    }

    public static string EncodeQuery(string s) => Uri.EscapeDataString(s);

    static string Hhmm(DateTime d) => d.ToString("HH:mm");

    public static async Task<JsonNode?> GetJson(string url, string? accept = null)
    {
        bool isOA = url.Contains("api.openalex.org");
        if (isOA && !string.IsNullOrEmpty(OpenAlexKey)) url += "&api_key=" + OpenAlexKey;
        if (Environment.GetEnvironmentVariable("BIBLIO_OFFLINE") != null) { LastIssue = "no internet connection (test)"; throw new NetworkException(LastIssue); }
        if (isOA && DateTime.Now < OpenAlexCooldownUntil) { LastIssue = $"OpenAlex limit reached (will retry after {Hhmm(OpenAlexCooldownUntil)})"; throw new NetworkException(LastIssue); }
        for (int attempt = 0; attempt < 4; attempt++)
        {
            try
            {
                await Throttle(isOA);
                using var req = new HttpRequestMessage(HttpMethod.Get, url);
                if (accept != null) req.Headers.Accept.ParseAdd(accept);
                using var resp = await Http.SendAsync(req);
                int code = (int)resp.StatusCode;
                if (code == 429 || code >= 500)
                {
                    if (isOA)
                    {
                        OpenAlexCooldownUntil = DateTime.Now.AddSeconds(string.IsNullOrEmpty(OpenAlexKey) ? 900 : 300);
                        LastIssue = $"OpenAlex limit reached (HTTP {code}; will retry after {Hhmm(OpenAlexCooldownUntil)})";
                        throw new NetworkException(LastIssue);
                    }
                    if (attempt < 3)
                    {
                        double wait = 1.5 * (attempt + 1);
                        if (resp.Headers.RetryAfter?.Delta is TimeSpan ra) wait = Math.Min(15, Math.Max(wait, ra.TotalSeconds));
                        await Task.Delay(TimeSpan.FromSeconds(wait)); continue;
                    }
                    LastIssue = $"Crossref/doi.org not responding (HTTP {code})";
                    throw new NetworkException(LastIssue);
                }
                if (code != 200) return null;
                await Task.Delay(60);
                var body = await resp.Content.ReadAsStringAsync();
                return JsonNode.Parse(body);
            }
            catch (NetworkException) { throw; }
            catch (HttpRequestException e)
            {
                LastIssue = "no internet connection or too slow (" + (e.InnerException?.Message ?? e.Message) + ")";
                throw new NetworkException(LastIssue);
            }
            catch (TaskCanceledException)
            {
                LastIssue = "no internet connection or too slow (timeout)";
                throw new NetworkException(LastIssue);
            }
            catch { return null; }
        }
        return null;
    }

    // JSON yardımcıları
    static string Str(JsonNode? n) { try { return n is JsonValue v ? (v.TryGetValue<string>(out var s) ? s : v.ToString()) : ""; } catch { return ""; } }
    static int? Int(JsonNode? n) { try { return n is JsonValue v && v.TryGetValue<int>(out var i) ? i : null; } catch { return null; } }
    static string FirstString(JsonNode? n) => n is JsonArray a && a.Count > 0 ? Str(a[0]) : "";

    static List<Person> Persons(JsonNode? arr)
    {
        var outp = new List<Person>();
        if (arr is not JsonArray a) return outp;
        foreach (var x in a)
        {
            var family = Str(x?["family"]);
            if (family.Length > 0) { outp.Add(new Person(family, Str(x?["given"]))); continue; }
            var name = Str(x?["name"]); if (name.Length == 0) name = Str(x?["literal"]);
            if (name.Length > 0) outp.Add(new Person(name, ""));
        }
        return outp;
    }

    static int? DateYear(JsonNode? o)
    {
        var dp = o?["date-parts"] as JsonArray;
        return dp is { Count: > 0 } && dp[0] is JsonArray first && first.Count > 0 ? Int(first[0]) : null;
    }

    public static Work CrossrefWork(JsonNode m)
    {
        var ps = Persons(m["author"]);
        int? year = null;
        foreach (var k in new[] { "published-print", "published-online", "issued", "published" })
        { var y = DateYear(m[k]); if (y != null) { year = y; break; } }
        var title = FirstString(m["title"]);
        var type = Str(m["type"]);
        var r = new Ref
        {
            Authors = ps, Editors = Persons(m["editor"]), Year = year, Title = title,
            Container = FirstString(m["container-title"]), Volume = Str(m["volume"]), Issue = Str(m["issue"]), Pages = Str(m["page"]),
            Doi = Str(m["DOI"]), Publisher = Str(m["publisher"]), Type = type,
        };
        return new Work { Authors = ps.Select(p => p.Family).ToList(), Year = year, Title = title, Type = type, Ref = r };
    }

    public static Work CslWork(JsonNode m)
    {
        var ps = Persons(m["author"]);
        var year = DateYear(m["issued"]);
        var title = Str(m["title"]);
        var type = Str(m["type"]);
        var r = new Ref
        {
            Authors = ps, Editors = Persons(m["editor"]), Year = year, Title = title,
            Container = Str(m["container-title"]), Volume = Str(m["volume"]), Issue = Str(m["issue"]), Pages = Str(m["page"]),
            Doi = Str(m["DOI"]), Publisher = Str(m["publisher"]), Type = type,
        };
        return new Work { Authors = ps.Select(p => p.Family).ToList(), Year = year, Title = title, Type = type, Ref = r };
    }

    static readonly string[] NameParticles = { "van", "von", "de", "der", "den", "da", "di", "la", "le", "ter", "bin", "al", "el", "du", "dos", "del" };

    /// <summary>"Matthew E. Kahn" -> (Kahn, Matthew E.); "Jan van der Heijden" -> (van der Heijden, Jan)</summary>
    public static Person SplitName(string full)
    {
        var toks = full.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (toks.Length <= 1) return new Person(full, "");
        int i = toks.Length - 1;
        while (i > 1 && NameParticles.Contains(toks[i - 1].ToLowerInvariant())) i--;
        return new Person(string.Join(" ", toks[i..]), string.Join(" ", toks[..i]));
    }

    public static Work OpenAlexWork(JsonNode m)
    {
        var names = new List<string>();
        if (m["authorships"] is JsonArray aa) foreach (var x in aa) { var n = Str(x?["author"]?["display_name"]); if (n.Length > 0) names.Add(n); }
        var ps = names.Select(SplitName).ToList();
        var biblio = m["biblio"];
        var fp = Str(biblio?["first_page"]); var lp = Str(biblio?["last_page"]);
        var src = m["primary_location"]?["source"];
        var doi = Str(m["doi"]).Replace("https://doi.org/", "");
        var year = Int(m["publication_year"]);
        var title = Str(m["display_name"]);
        var type = Str(m["type"]);
        var r = new Ref
        {
            Authors = ps, Year = year, Title = title, Container = Str(src?["display_name"]),
            Volume = Str(biblio?["volume"]), Issue = Str(biblio?["issue"]),
            Pages = fp.Length == 0 ? "" : (lp.Length == 0 || lp == fp ? fp : fp + "-" + lp), Doi = doi,
            Publisher = Str(src?["host_organization_name"]), Type = type == "article" ? "journal-article" : type,
        };
        return new Work { Authors = ps.Select(p => p.Family).ToList(), Year = year, Title = title, Type = type, Ref = r };
    }

    public static async Task<Work?> ResolveDOI(string d)
    {
        var enc = Uri.EscapeDataString(d).Replace("%2F", "/");
        var j = await GetJson("https://api.crossref.org/works/" + enc);
        if (j?["message"] is JsonNode msg)
        {
            var w = CrossrefWork(msg);
            if (w.Authors.Count > 0 && w.Year != null) return w;
        }
        j = await GetJson("https://doi.org/" + enc, "application/vnd.citationstyles.csl+json");
        if (j != null)
        {
            var w = CslWork(j);
            if (w.Authors.Count > 0 && w.Year != null) return w;
        }
        return null;
    }

    public static bool Acceptable(Work w, string text)
    {
        if (w.Authors.Count == 0 || w.Year == null || w.Year > CurrentYear + 1 || w.Title.Length == 0) return false;
        int y = w.Year.Value;
        int maxYear = Text_.Matches(@"\b(?:19|20)\d{2}\b", text).Select(int.Parse).Where(v => v <= CurrentYear).DefaultIfEmpty(0).Max();
        if (y + 15 < maxYear) return false;
        if (!(ContainsPhrase(text, w.Title) && AuthorOnPage(w.Authors, text))) return false;
        if (Text_.Squash(w.Title).Length < 20)
        {
            var top = string.Join("\n", text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Take(10));
            return AuthorOnPage(new[] { w.Authors[0] }, top);
        }
        return true;
    }

    // MARK: Çözümleme
    public static List<(string Doi, bool Trusted)> IdDOIs(string page, string filename)
    {
        var outp = new List<(string, bool)>();
        foreach (var n in Text_.Matches(@"(?i)^ssrn[-_ ]?(\d{6,8})", filename, 1)) outp.Add(("10.2139/ssrn." + n, true));
        foreach (var n in Text_.Matches(@"(?i)ssrn\.com/abstract[=_ ]*(\d{6,8})", page, 1)) outp.Add(("10.2139/ssrn." + n, false));
        foreach (var n in Text_.Matches(@"(?i)arxiv:\s*(\d{4}\.\d{4,5})", page, 1)) outp.Add(("10.48550/arXiv." + n, false));
        foreach (var n in Text_.Matches(@"(?i)NBER Working Paper (?:Series )?(?:No\.?\s*)?(\d{3,5})", page, 1)) outp.Add(("10.3386/w" + n, false));
        var seen = new HashSet<string>();
        return outp.Where(x => seen.Add(x.Item1)).Take(3).ToList();
    }

    public static bool IsbnValid(string d)
    {
        var c = d.ToUpperInvariant();
        if (c.Length == 13 && c.All(char.IsDigit))
            return c.Select((ch, i) => (ch - '0') * (i % 2 == 0 ? 1 : 3)).Sum() % 10 == 0;
        if (c.Length == 10)
        {
            int sum = 0;
            for (int i = 0; i < 10; i++)
            {
                int v = (c[i] == 'X' && i == 9) ? 10 : (char.IsDigit(c[i]) ? c[i] - '0' : -100);
                sum += v * (10 - i);
            }
            return sum % 11 == 0;
        }
        return false;
    }

    public static List<string> Isbns(string page, string filename)
    {
        var outp = new List<string>();
        foreach (var m in Text_.Matches(@"(?i)ISBN(?:-1[03])?:?\s*([\dXx\- ]{10,17})", page + " " + filename, 1))
            outp.Add(m.Replace("-", "").Replace(" ", ""));
        outp.AddRange(Text_.Matches(@"(?<![\dA-Za-z])(97[89]\d{10})(?![\dA-Za-z])", filename, 1));
        var seen = new HashSet<string>();
        return outp.Where(x => IsbnValid(x) && seen.Add(x)).ToList();
    }

    static readonly string[] JunkWords = { "http", "www.", "doi", "issn", "contents lists", "journal homepage", "©", "downloaded", "available online",
        "electronic copy", "working paper", "vol.", "volume", "sciencedirect", "elsevier", "springer", "wiley", "jstor" };

    public static bool IsJunk(string l)
    {
        var low = l.ToLowerInvariant();
        if (l.Length < 4) return true;
        if (JunkWords.Any(low.Contains)) return true;
        int digits = l.Count(char.IsDigit);
        return (double)digits / l.Length > 0.25;
    }

    public static List<string> Queries(PageData data)
    {
        List<string> CleanLines(string page) => page.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(x => x.Trim()).Take(40).Where(x => !IsJunk(x)).Take(10).ToList();
        var clean = data.Pages.Select(CleanLines).FirstOrDefault(c => c.Count >= 2) ?? CleanLines(data.Pages.FirstOrDefault() ?? "");
        var outp = new List<string>();
        var flat = data.Text.Replace("\n", " ");
        var g = Text_.Groups(@"^\s*(.{8,200}?)\s+Author\(s\):", flat); if (g != null) outp.Add(g[0]);
        g = Text_.Groups(@"Suggested Citation:.{0,200}?\((?:19|20)\d{2}\)\s*:\s*([^,]{6,150})", flat); if (g != null) outp.Add(g[0]);
        if (clean.Count >= 2) outp.Add(string.Join(" ", clean.Take(2)));
        if (clean.Count >= 3) outp.Add(string.Join(" ", clean.Take(3)));
        foreach (var l in clean.Take(6)) if (l.Length >= 18) outp.Add(l);
        for (int i = 0; i < Math.Max(0, Math.Min(clean.Count, 6) - 1); i++) outp.Add(clean[i] + " " + clean[i + 1]);
        var seen = new HashSet<string>();
        return outp.Select(x => x.Length > 250 ? x[..250] : x).Where(x => seen.Add(x)).Take(8).ToList();
    }

    public static async Task<Found?> Lookup(PageData data)
    {
        var c = CoverParse(data);
        if (c != null) return new Found { Authors = c.Value.Item1, Year = c.Value.Item2, How = "cover" };
        if (UseFilename) { var g = FilenameGuess(data.Filename); if (g != null) return new Found { Authors = g.Value.Item1, Year = g.Value.Item2, How = "filename" }; }
        if (OnlineEnabled) { var f = await LookupOnline(data); if (f != null) return f; }
        return LocalFallback(data);
    }

    public static async Task<Found?> LookupOnline(PageData data)
    {
        var text = data.Text;
        var first = data.Pages.FirstOrDefault() ?? "";
        var head = first.Length > 1200 ? first[..1200] : first;
        bool degraded = false;

        foreach (var (d, trusted) in IdDOIs(first, data.Filename))
        {
            var w = await ResolveDOI(d);
            if (w?.Year is int y && (trusted || Acceptable(w, text)))
                return new Found { Authors = w.Authors, Year = y, How = "id", Ref = w.Ref };
        }
        var dois = new List<string>();
        foreach (var d in Text_.Matches(@"10\.\d{4,9}/[^\s""<>]+", text))
        {
            var t = d.Trim(".,;)]}".ToCharArray());
            if (!dois.Contains(t)) dois.Add(t);
        }
        foreach (var d in dois.Take(3))
        {
            var w = await ResolveDOI(d);
            if (w?.Year is int y && (TitleInText(w.Title, text) || ContainsPhrase(text, w.Title) || (head.Contains(d) && text.Length < 1500)))
                return new Found { Authors = w.Authors, Year = y, How = "doi", Ref = w.Ref };
        }
        foreach (var isbn in Isbns(first, data.Filename).Take(2))
        {
            var j = await GetJson($"https://openlibrary.org/api/books?bibkeys=ISBN:{isbn}&format=json&jscmd=data");
            var b = j?["ISBN:" + isbn];
            if (b == null) continue;
            var au = (b["authors"] as JsonArray)?.Select(a => Str(a?["name"])).Where(n => n.Length > 0).ToList() ?? new();
            var yy = Text_.Matches(@"(?:19|20)\d{2}", Str(b["publish_date"])).Select(int.Parse).Cast<int?>().FirstOrDefault();
            if (au.Count > 0 && yy != null)
            {
                var pubs = (b["publishers"] as JsonArray)?.Select(a => Str(a?["name"])).FirstOrDefault() ?? "";
                var r = new Ref { Authors = au.Select(SplitName).ToList(), Year = yy, Title = Str(b["title"]), Publisher = pubs, Type = "book" };
                return new Found { Authors = au.Select(n => n.Split(' ', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? n).ToList(), Year = yy, How = "isbn", Ref = r };
            }
        }
        foreach (var q in Queries(data))
        {
            var enc = EncodeQuery(q);
            var j = await GetJson("https://api.crossref.org/works?rows=8&select=author,editor,issued,published-print,published-online,title,type,container-title,volume,issue,page,DOI,publisher&query.bibliographic=" + enc);
            if (j?["message"]?["items"] is JsonArray items)
            {
                var works = items.Where(i => i != null).Select(i => CrossrefWork(i!)).OrderBy(w => w.Type == "journal-article" ? 0 : 1).ToList();
                var w = works.FirstOrDefault(x => Acceptable(x, text));
                if (w != null) return new Found { Authors = w.Authors, Year = w.Year, How = "title", Ref = w.Ref };
            }
            try
            {
                var jo = await GetJson("https://api.openalex.org/works?per-page=6&select=display_name,publication_year,authorships,type,doi,biblio,primary_location&search=" + enc);
                if (jo?["results"] is JsonArray res)
                {
                    var w = res.Where(i => i != null).Select(i => OpenAlexWork(i!)).FirstOrDefault(x => Acceptable(x, text));
                    if (w != null) return new Found { Authors = w.Authors, Year = w.Year, How = "working-paper", Ref = w.Ref };
                }
            }
            catch (NetworkException) { degraded = true; }
        }
        if (degraded) throw new NetworkException(LastIssue);
        return null;
    }

    public static Found? LocalFallback(PageData data)
    {
        if (!GuessEnabled) return null;
        var first = data.Pages.FirstOrDefault() ?? "";
        var g = LocalGuess(first);
        if (g != null) return new Found { Authors = g.Value.Item1, Year = g.Value.Item2, How = data.Ocr ? "ocr+text" : "text" };
        if (data.MetaAuthor != null)
        {
            var top = string.Join("\n", first.Split('\n', StringSplitOptions.RemoveEmptyEntries).Take(30));
            var people = SplitPeople(data.MetaAuthor.Replace(",", " and "));
            var s = people.Select(Surname).Where(x => x != null).Select(x => x!).Where(x => Text_.Squash(x).Length >= 3 && Text_.Squash(top).Contains(Text_.Squash(x))).ToList();
            if (s.Count > 0 && s.Count == people.Count) return new Found { Authors = s, Year = GuessYear(first), How = "pdf-author" };
        }
        return null;
    }

    // MARK: Kapak sayfası biçimleri
    public static List<string> SurnameFromList(IEnumerable<string> people) =>
        people.Select(p =>
        {
            var t = p.Trim();
            int c = t.IndexOf(',');
            return c >= 0 ? t[..c].Trim() : Surname(t) ?? "";
        }).Where(x => x.Length > 0).ToList();

    public static List<string> SplitPeople(string s)
    {
        var parts = new List<string> { s };
        foreach (var sep in new[] { " and ", " & ", " ve ", ";" }) parts = parts.SelectMany(p => p.Split(sep)).ToList();
        return parts.Select(p => p.Trim()).Where(p => p.Length > 0).ToList();
    }

    public static (List<string>, int)? CoverParse(PageData data)
    {
        var flat = data.Text.Replace("\n", " ");
        var g = Text_.Groups(@"Author\(s\):\s*(.+?)\s+Source:\s*(.+?)(?:\s+Published by:|\s+Stable URL:|$)", flat);
        if (g != null)
        {
            var people = g[0].Split(", ").SelectMany(SplitPeople).ToList();
            var ys = Text_.Matches(@"(?:19|20)\d{2}", g[1]).Select(int.Parse).Where(v => v <= CurrentYear).ToList();
            if (ys.Count > 0 && people.Count > 0)
            {
                var s = people.Select(Surname).Where(x => x != null).Select(x => x!).ToList();
                if (s.Count > 0) return (s, ys[0]);
            }
        }
        g = Text_.Groups(@"Suggested Citation:\s*(.+?)\s*\(((?:19|20)\d{2})\)", flat);
        if (g != null && g[0].Length < 220 && int.TryParse(g[1], out var y2))
        {
            var people = g[0].Contains(';') ? g[0].Split(';').ToList() : SplitPeople(g[0]);
            var s = SurnameFromList(people.Select(p => p.Replace(" et al.", "")));
            if (s.Count > 0) return (s, y2);
        }
        if (flat.Contains("Munich Personal RePEc Archive") && GuessYear(data.Pages.FirstOrDefault() ?? "") is int y3)
        {
            const string re = @"^(?:and )?\p{Lu}[\p{L}'’\-]+, \p{Lu}";
            var lines = (data.Pages.FirstOrDefault() ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => l.Trim()).ToList();
            int start = lines.FindIndex(l => Regex.IsMatch(l, re));
            if (start >= 0)
            {
                var acc = new List<string>();
                int i = start;
                while (i < lines.Count && Regex.IsMatch(lines[i], re)) { acc.Add(lines[i]); i++; }
                var people = string.Join(" ", acc).Split(" and ").Select(p => p.StartsWith("and ") ? p[4..] : p).ToList();
                var s = SurnameFromList(people);
                if (s.Count > 0) return (s, y3);
            }
        }
        return null;
    }

    // MARK: İlk sayfadan yazar ve yıl tahmini
    static readonly string[] AffiliationWords = { "university", "üniversite", "universit", "institute", "enstitü", "department", "bölüm", "school",
        "college", "center", "centre", "faculty", "fakülte", "bank", "@", "bilim dalı", "laboratory", "research", "institut", "universidad", "ministry", "bakanlığı" };
    static readonly string[] BlockWords = { "abstract", "özet", "working", "paper", "journal", "dergi", "keywords", "introduction", "giriş", "draft",
        "tezi", "thesis", "danışman", "hazırlayan", "editör", "editor", "series", "discussion", "report", "rapor",
        "senior", "economist", "professor", "prof.", "director", "researcher", "lecturer", "associate", "fellow", "analyst", "manager", "assistant" };
    static readonly HashSet<string> TitleWords = new()
    {
        "jobs","skills","green","energy","economy","economic","policy","analysis","impact","impacts","effects","effect","labor","labour","employment","growth",
        "development","environmental","climate","evidence","market","markets","theory","model","models","review","study","international","national","global",
        "sustainable","renewable","innovation","education","training",
    };

    public static int? GuessYear(string page)
    {
        var top = string.Join("\n", page.Split('\n', StringSplitOptions.RemoveEmptyEntries).Take(10));
        foreach (var m in Text_.Matches(@"\(\s*((?:19|20)\d{2})\s*\)\s*\d", top, 1))
            if (int.Parse(m) <= CurrentYear) return int.Parse(m);
        const string months = "january|february|march|april|may|june|july|august|september|october|november|december|ocak|şubat|mart|nisan|mayıs|haziran|temmuz|ağustos|eylül|ekim|kasım|aralık";
        var patterns = new[]
        {
            $@"(?i)\b(?:{months})\b[^A-Za-z0-9]{{0,2}}[0-9,\s\-–]{{0,14}}?\b((?:19|20)\d{{2}})\b",
            @"(?i)(?:©|\(c\)|copyright)\s*(?:[A-Za-z ,.()]{0,60})?((?:19|20)\d{2})",
            @"(?i)(?:received|accepted|published|available online|revised|submitted)[^\n]{0,40}?\b((?:19|20)\d{2})\b",
            @"(?m)^[^\n]{0,30}[–—-]\s*((?:19|20)\d{2})\s*$",
        };
        var years = new List<int>();
        foreach (var p in patterns) years.AddRange(Text_.Matches(p, page, 1).Select(int.Parse).Where(v => v <= CurrentYear));
        return years.Count == 0 ? null : years.Max();
    }

    public static List<string>? NameParts(string raw)
    {
        var low = raw.ToLowerInvariant();
        if (AffiliationWords.Any(low.Contains) || BlockWords.Any(low.Contains)) return null;
        if (raw.Any(char.IsDigit)) return null;
        var parts = new List<string> { raw };
        foreach (var sep in new[] { " and ", " & ", " ve ", ",", ";" }) parts = parts.SelectMany(p => p.Split(sep)).ToList();
        parts = parts.Select(p => p.Trim()).Where(p => p.Length > 0).ToList();
        if (parts.Count == 0) return null;
        foreach (var p in parts)
        {
            var toks = p.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (toks.Length < 2 || toks.Length > 4) return null;
            foreach (var t in toks) if (!Regex.IsMatch(t, @"^\p{Lu}[\p{L}'’.\-]*$")) return null;
            if (toks.Length >= 3 && toks.All(Text_.IsAllUpper)) return null;
        }
        return parts;
    }

    public static string? Surname(string person)
    {
        var toks = person.Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(t => t.Replace(".", "").Length >= 2).ToList();
        if (toks.Count == 0) return null;
        var caps = toks.Where(t => Text_.IsAllUpper(t) && t.Length > 1).ToList();
        if (caps.Count == 1 && toks.Count > 1) return caps[0];
        return toks[^1];
    }

    static HashSet<char> AffLabels(string page)
    {
        var outp = new HashSet<char>();
        foreach (var l in page.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var g = Text_.Groups(@"^([a-h](?:\s*,\s*[a-h])*)\s*\p{Lu}", l);
            if (g != null) foreach (var c in g[0]) if (char.IsLetter(c)) outp.Add(c);
        }
        return outp;
    }

    static string CleanAuthorLine(string raw, HashSet<char> labels, string page)
    {
        var line = Regex.Replace(raw, @"[*†‡§¶‖⁎✉☆∗·•]+", ",");
        line = Regex.Replace(line, @"(?<=\p{L})\d+", "");
        var outp = new List<string>();
        foreach (var tok in line.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (tok.All(c => "abcdefgh,".Contains(c))) continue;
            string core = tok, punct = "";
            while (core.Length > 0 && ",;".Contains(core[^1])) { punct = core[^1] + punct; core = core[..^1]; }
            if (core.Length >= 4 && labels.Contains(core[^1]) && page.Split(core).Length - 1 == 1) core = core[..^1];
            if (new[] { "Jr", "Jr.", "Sr", "Sr.", "II", "III", "IV" }.Contains(core)) continue;
            outp.Add(core + punct);
        }
        return string.Join(" ", outp);
    }

    public static (List<string>, int?)? LocalGuess(string page)
    {
        var year = GuessYear(page);
        var lines = page.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
        var head = lines.Take(60).ToList();
        var labels = AffLabels(page);
        var authors = new List<string>();
        for (int i = 0; i < head.Count; i++)
        {
            var line = CleanAuthorLine(head[i], labels, page);
            bool byCue = false;
            if (Regex.IsMatch(line, @"^(?i)by\s+")) { byCue = true; line = Regex.Replace(line, @"^(?i)by\s+", ""); }
            line = Regex.Replace(line, @"\d+$", "").Trim(", ".ToCharArray());
            var people = NameParts(line);
            if (people == null) continue;
            var prev = i > 0 ? head[i - 1].ToLowerInvariant().Trim(": ".ToCharArray()) : "";
            bool cue = byCue || new[] { "hazırlayan", "yazar", "author", "authors", "by", "tarafından" }.Contains(prev);
            var next = string.Join(" ", head.Skip(i + 1).Take(Math.Min(i + 3, head.Count) - (i + 1))).ToLowerInvariant();
            bool affiliated = AffiliationWords.Any(next.Contains);
            bool list = i < 14 && people.Count >= 2 && !people.Any(p => p.ToLowerInvariant().Split(' ').Any(TitleWords.Contains));
            if (cue || affiliated || list)
                foreach (var p in people) { var s = Surname(p); if (s != null && !authors.Contains(s)) authors.Add(s); }
        }
        authors = authors.Take(6).ToList();
        return authors.Count == 0 ? null : (authors, year);
    }

    static readonly string[] BadNames = { "annual", "table", "figure", "chapter", "notes" };

    public static (List<string>, int)? FilenameGuess(string name)
    {
        var stem = Regex.Replace(name.Normalize(), @"\.pdf$", "", RegexOptions.IgnoreCase).Replace("_", " ");
        var g = Text_.Groups(@"^(\p{Lu}[\p{L}'’\-]+(?:\s*(?:,|&|and)\s*\p{Lu}[\p{L}'’\-]+){0,3})\s*[-–]?\s*((?:19|20)\d{2})\b", stem);
        if (g == null || !int.TryParse(g[1], out var y) || y > CurrentYear) return null;
        var people = g[0].Split(',', '&').SelectMany(x => x.Split(" and ")).Select(x => x.Trim()).Where(x => x.Length > 0).ToList();
        bool bad = people.Any(p => BlockWords.Contains(p.ToLowerInvariant()) || TitleWords.Contains(p.ToLowerInvariant()) || BadNames.Contains(p.ToLowerInvariant()));
        bool acronym = people.Any(p => p.Length < 3 || p == p.ToUpperInvariant());
        return (people.Count == 0 || bad || acronym) ? null : (people, y);
    }

    public static string? BaseName(IList<string> authors, int? year) =>
        authors.Count == 0 ? null : Namer.Render(new NameFields { Authors = authors.ToList(), Year = year }, new NamingPrefs());

    public static (string First, int? Year)? ParseNamed(string stem)
    {
        var g = Text_.Groups(@"^(.+?) - ((?:19|20)\d{2}|xxxx)[a-z]?$", stem);
        if (g == null) return null;
        var a = g[0];
        foreach (var sep in new[] { " et al", " & " }) { int i = a.IndexOf(sep, StringComparison.Ordinal); if (i >= 0) a = a[..i]; }
        return (a, int.TryParse(g[1], out var y) ? y : null);
    }

    public static bool AlreadyNamed(string stem) => Regex.IsMatch(stem, @"^.+ - ((19|20)\d{2}|xxxx)[a-z]?$");
}

public static class Flag
{
    public const string Prefix = "!! ";   // çözülemeyen dosyalar: klasör listesinin en üstünde sıralanır
    public static string Strip(string s) => s.StartsWith(Prefix) ? s[Prefix.Length..] : s;
}
