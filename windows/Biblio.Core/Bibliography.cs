using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Biblio.Core;

/// <summary>Kaynakça listesindeki bir eserin bulunan sürümleri (makale, çalışma kâğıdı/preprint…).</summary>
public class RefVersion
{
    public string Label = "";       // "article", "working paper/preprint" … (İngilizce anahtar; gösterimde çevrilir)
    public string? Pdf;             // açık erişimli doğrudan PDF bağlantısı
    public int? Year;
    public bool IsPublished => Label.StartsWith("article");
}

public class RefResult
{
    public string Title = "";
    public string? Doi;
    public int? Year;
    public List<RefVersion> Versions = new();
    public string? Landing;         // makalenin sayfası (https://doi.org/…)
    public bool OpenAlexDown;
}

/// <summary>Kaynakça dosyasını (.docx/.txt) okur; her satırı Crossref/OpenAlex'te bulur ve açık erişimli PDF'leri indirir (Swift: enum Biblio).</summary>
public static class Bibliography
{
    // MARK: Kaynakça dosyasını okuma (.docx, .txt)

    static readonly string[] SkipHeads = { "kaynakça", "kaynaklar", "references", "bibliography", "kaynakca" };

    public static List<string> Entries(string path)
    {
        var raw = path.EndsWith(".docx", StringComparison.OrdinalIgnoreCase) ? DocxParagraphs(path) : TxtEntries(path);
        return raw.Select(r => r.Trim())
            .Where(r => r.Length >= 25 && !SkipHeads.Contains(r.ToLowerInvariant()) && Regex.IsMatch(r, @"(?:19|20)\d{2}|\(n\.d\.\)"))
            .ToList();
    }

    static string Unescape(string s) =>
        s.Replace("&lt;", "<").Replace("&gt;", ">").Replace("&quot;", "\"").Replace("&apos;", "'").Replace("&amp;", "&");

    public static List<string> DocxParagraphs(string path)
    {
        string xml;
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var zip = new ZipArchive(fs, ZipArchiveMode.Read);
            var e = zip.GetEntry("word/document.xml");
            if (e == null) return new();
            using var r = new StreamReader(e.Open(), Encoding.UTF8);
            xml = r.ReadToEnd();
        }
        catch { return new(); }
        var para = new Regex(@"<w:p[ >].*?</w:p>", RegexOptions.Singleline);
        var run = new Regex(@"<w:t(?: [^>]*)?>([^<]*)</w:t>|<w:tab/>|<w:br/>");
        var outp = new List<string>();
        foreach (Match m in para.Matches(xml))
        {
            var sb = new StringBuilder();
            foreach (Match r in run.Matches(m.Value)) sb.Append(r.Groups[1].Success ? r.Groups[1].Value : " ");
            outp.Add(Unescape(sb.ToString()));
        }
        return outp;
    }

    public static List<string> TxtEntries(string path)
    {
        string text;
        try
        {
            var bytes = File.ReadAllBytes(path);
            try { text = new UTF8Encoding(false, true).GetString(bytes); }
            catch { text = Encoding.Latin1.GetString(bytes); }
        }
        catch { return new(); }
        var t = text.Replace("\r\n", "\n");
        var blocks = t.Split("\n\n").Select(b => string.Join(" ", b.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0))).Where(b => b.Length > 0).ToList();
        if (blocks.Count > 1) return blocks;
        // boş satır yoksa: girintili (asılı) satırlar öncekine eklenir, diğer her satır ayrı kaynak
        var outp = new List<string>();
        foreach (var line in t.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            if ((line[0] == ' ' || line[0] == '\t') && outp.Count > 0) outp[^1] += " " + line.Trim();
            else outp.Add(line.Trim());
        }
        return outp;
    }

    // MARK: Çözümleme

    public static string Cleaned(string s)
    {
        var t = s.Replace("*", "");
        t = Regex.Replace(t, @"https?://\S+", " ");
        t = Regex.Replace(t, @"(?i)\bdoi:?\s*\S+", " ");
        return string.Join(" ", t.Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    public static string? FirstDoi(string s) =>
        Text_.Matches(@"10\.\d{4,9}/[^\s""<>]+", s).FirstOrDefault()?.Trim(".,;)]}".ToCharArray());

    /// <summary>Kaynakça satırı Crossref adayıyla uyuşuyor mu: başlık aynen, ilk yazar soyadı ve yıl (±1) satırda geçmeli.</summary>
    public static bool Matches(Work w, string entry)
    {
        if (w.Year is not int y || w.Authors.Count == 0 || !Engine.ContainsPhrase(entry, w.Title) || !Engine.AuthorOnPage(new[] { w.Authors[0] }, entry)) return false;
        var years = Text_.Matches(@"(?:19|20)\d{2}", entry).Select(int.Parse).ToList();
        return years.Count == 0 || years.Any(v => Math.Abs(v - y) <= 1);
    }

    public static string LabelForType(string t) => t switch
    {
        "article" or "journal-article" => "article",
        "preprint" or "posted-content" => "working paper/preprint",
        "report" or "working-paper" => "working paper/report",
        "book-chapter" => "book chapter",
        "book" => "book",
        _ => t.Length == 0 ? "version" : t,
    };

    static string? PdfUrl(JsonNode? loc) => loc?["pdf_url"] is JsonValue v && v.TryGetValue<string>(out var s) && Uri.IsWellFormedUriString(s, UriKind.Absolute) ? s : null;

    public static List<RefVersion> Versions(JsonNode item)
    {
        int? year = item["publication_year"] is JsonValue yv && yv.TryGetValue<int>(out var yi) ? yi : null;
        var def = LabelForType(item["type"] is JsonValue tv && tv.TryGetValue<string>(out var ts) ? ts : "");
        var outp = new List<RefVersion>();
        if (item["locations"] is JsonArray locs)
            foreach (var loc in locs)
            {
                var u = PdfUrl(loc);
                if (u == null) continue;
                var ver = loc?["version"] is JsonValue vv && vv.TryGetValue<string>(out var vs) ? vs : "";
                var lab = ver switch
                {
                    "publishedVersion" => "article",
                    "acceptedVersion" => "article (accepted version)",
                    "submittedVersion" => "working paper/preprint",
                    _ => def,
                };
                outp.Add(new RefVersion { Label = lab, Pdf = u, Year = year });
            }
        if (outp.Count == 0 && PdfUrl(item["best_oa_location"]) is string b) outp.Add(new RefVersion { Label = def, Pdf = b, Year = year });
        return outp;
    }

    public static async Task<RefResult?> Resolve(string raw)
    {
        var entry = Cleaned(raw);
        // 1) Crossref: DOI varsa doğrudan, yoksa tüm künyeyi sorgu olarak ver ve doğrula
        Work? found = null;
        if (FirstDoi(raw) is string d) found = await Engine.ResolveDOI(d);
        if (found == null)
        {
            var enc = Engine.EncodeQuery(entry.Length > 300 ? entry[..300] : entry);
            var j = await Engine.GetJson("https://api.crossref.org/works?rows=6&select=author,editor,issued,published-print,published-online,title,type,container-title,volume,issue,page,DOI,publisher&query.bibliographic=" + enc);
            if (j?["message"]?["items"] is JsonArray items)
            {
                var works = items.Where(i => i != null).Select(i => Engine.CrossrefWork(i!)).OrderBy(w => w.Type == "journal-article" ? 0 : 1).ToList();
                found = works.FirstOrDefault(w => Matches(w, entry));
            }
        }
        if (found?.Ref is not Ref rf || found.Title.Length == 0) return null;
        var doi = rf.Doi.Length == 0 ? null : rf.Doi;
        var result = new RefResult { Title = found.Title, Doi = doi, Year = found.Year, Landing = doi == null ? null : "https://doi.org/" + doi };

        // 2) OpenAlex: aynı başlıklı tüm sürümler (makale + çalışma kâğıdı/preprint) ve açık erişimli PDF bağlantıları
        try
        {
            var enc = Engine.EncodeQuery(found.Title);
            var j = await Engine.GetJson($"https://api.openalex.org/works?per-page=10&search={enc}&select=id,doi,display_name,type,publication_year,authorships,best_oa_location,locations");
            if (j?["results"] is JsonArray results)
            {
                var want = Text_.Norm(found.Title);
                var a0 = Text_.Squash(found.Authors[0]);
                var seen = new HashSet<string>();
                foreach (var it in results)
                {
                    if (it == null) continue;
                    var ow = Engine.OpenAlexWork(it);
                    if (Text_.Norm(ow.Title) != want || ow.Authors.Count == 0) continue;
                    var first = Text_.Squash(ow.Authors[0]);
                    if (first.Length < 3 || !(a0.Contains(first) || first.Contains(a0))) continue;
                    foreach (var v in Versions(it)) if (seen.Add(v.Pdf!)) result.Versions.Add(v);
                }
            }
        }
        catch (NetworkException) { result.OpenAlexDown = true; }
        result.Versions = result.Versions.Take(4).ToList();
        return result;
    }

    /// <summary>Aynı PDF farklı bağlantılardan (yayıncı, NBER, doi.org) gelebilir: içeriğe göre ayırt etmek için.</summary>
    public static string Fingerprint(string path)
    {
        try { using var fs = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(fs)); }
        catch { return Guid.NewGuid().ToString(); }
    }

    // MARK: İndirme (yalnızca açık erişimli doğrudan PDF bağlantıları)

    static readonly HttpClient Dl = MakeClient();
    static HttpClient MakeClient()
    {
        var c = new HttpClient(new HttpClientHandler { AutomaticDecompression = DecompressionMethods.All, AllowAutoRedirect = true }) { Timeout = TimeSpan.FromSeconds(60) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) Biblio/1.0");
        c.DefaultRequestHeaders.Accept.ParseAdd("application/pdf,*/*");
        return c;
    }

    public static async Task<string?> DownloadPdf(string url, string folder, string stem)
    {
        var tmp = Path.Combine(Path.GetTempPath(), "biblio-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using var resp = await Dl.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            if (resp.StatusCode != HttpStatusCode.OK) return null;
            await using (var fs = File.Create(tmp)) await resp.Content.CopyToAsync(fs);
            var len = new FileInfo(tmp).Length;
            var head = new byte[5];
            using (var fs = File.OpenRead(tmp)) { if (fs.Read(head, 0, 5) < 5) return null; }
            if (Encoding.ASCII.GetString(head) != "%PDF-" || len < 20_000) return null;   // PDF değil (giriş/abonelik sayfası) ya da çok küçük
            Directory.CreateDirectory(folder);
            var dest = Path.Combine(folder, stem + ".pdf");
            int n = 2;
            while (File.Exists(dest)) { dest = Path.Combine(folder, $"{stem}-{n}.pdf"); n++; }
            File.Move(tmp, dest);
            return dest;
        }
        catch { return null; }
        finally { try { if (File.Exists(tmp)) File.Delete(tmp); } catch { } }
    }
}
