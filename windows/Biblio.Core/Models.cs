using System.Text.Json;
using System.Text.Json.Serialization;

namespace Biblio.Core;

public record Person(string Family, string Given);

/// <summary>Künye için tam yayın bilgisi (Crossref, doi.org, OpenAlex, Open Library).</summary>
public class Ref
{
    public List<Person> Authors { get; set; } = new();
    public List<Person> Editors { get; set; } = new();
    public int? Year { get; set; }
    public string Title { get; set; } = "";
    public string Container { get; set; } = "";
    public string Volume { get; set; } = "";
    public string Issue { get; set; } = "";
    public string Pages { get; set; } = "";
    public string Doi { get; set; } = "";
    public string Publisher { get; set; } = "";
    public string Type { get; set; } = "";
}

public class Found
{
    public List<string> Authors { get; set; } = new();
    public int? Year { get; set; }     // bulunamazsa dosya adında "xxxx"
    public string How { get; set; } = "";
    public Ref? Ref { get; set; }
}

public class PageData
{
    public List<string> Pages { get; set; } = new();
    public string? MetaAuthor { get; set; }
    public bool Ocr { get; set; }
    public string Filename { get; set; } = "";
    public string Text => string.Join("\n", Pages);
}

public class Work
{
    public List<string> Authors { get; set; } = new();
    public int? Year { get; set; }
    public string Title { get; set; } = "";
    public string Type { get; set; } = "";
    public Ref? Ref { get; set; }
}

public class NetworkException : Exception { public NetworkException(string m) : base(m) { } }

/// <summary>Saklanan künye. Mac sürümüyle aynı JSON biçimi (camelCase): aynı klasör iki sistemde de kullanılabilir.</summary>
public class RefEntry
{
    public string Key { get; set; } = "";
    public Ref? Ref { get; set; }
    public string? Text { get; set; }

    public RefEntry() { }
    public RefEntry(Ref r)
    {
        Ref = r;
        var doi = r.Doi.ToLowerInvariant();
        Key = doi.Length == 0 ? "t:" + Text_.Squash(r.Title) + "|" + (r.Year ?? 0) : "d:" + doi;
    }
    public RefEntry(string text, string? key = null)
    {
        Text = text;
        Key = key ?? "x:" + Text_.Squash(text);
    }

    [JsonIgnore]
    public bool NeedsCheck
    {
        get
        {
            if (Ref is { } r)
                return r.Year == null || string.IsNullOrWhiteSpace(r.Title) || r.Authors.Count == 0
                    || (r.Type == "journal-article" && string.IsNullOrWhiteSpace(r.Container));
            return Key.StartsWith("m:");
        }
    }

    public string Render(CiteStyle style) => Ref != null ? Cite.Format(Ref, style) : (Text ?? "");

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = true,
    };
}

public enum OutcomeKind { Renamed, Skipped, Pending, Kunye, Flagged }

public class Outcome
{
    public OutcomeKind Kind { get; init; }
    public string Path { get; init; } = "";       // asıl dosya
    public string? To { get; init; }              // yeni yol (Renamed/Flagged)
    public string Note { get; init; } = "";       // how / neden
    public RefEntry? Entry { get; init; }
}
