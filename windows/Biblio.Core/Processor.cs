using System.Text.Json;

namespace Biblio.Core;

/// <summary>Bir PDF'i çözümler ve yeniden adlandırır (Swift: actor Processor).</summary>
public class Processor
{
    readonly HashSet<string> reserved = new(StringComparer.OrdinalIgnoreCase);
    readonly object gate = new();

    bool Exists(string dir, string stem)
    {
        var p = Path.Combine(dir, stem + ".pdf");
        lock (gate) return File.Exists(p) || reserved.Contains(p);
    }

    string UniqueStem(string dir, NameFields f, NamingPrefs prefs)
    {
        var b = Namer.Render(f, prefs);
        var letters = "abcdefghijklmnopqrstuvwxyz".Select(c => c.ToString()).ToList();
        bool any = Exists(dir, b) || letters.Any(l => Exists(dir, Namer.Render(f, prefs, l)));
        if (!any) return b;
        foreach (var l in letters.Skip(1))
        {
            var n = Namer.Render(f, prefs, l);
            if (!Exists(dir, n)) return n;
        }
        return b + "-" + Guid.NewGuid().ToString("N")[..4];
    }

    static string PendingReason() => Engine.LastIssue.Length == 0 ? "network/limit problem" : Engine.LastIssue;

    /// <summary>Elle girilen bilgiyle yeniden adlandırır.</summary>
    public Outcome RenameManual(string path, IList<string> authors, int? year, Ref r, RefEntry entry)
    {
        if (!File.Exists(path)) return new Outcome { Kind = OutcomeKind.Skipped, Path = path, Note = "file not found" };
        var fields = new NameFields { Authors = authors.ToList(), Year = year, Title = r.Title, Journal = r.Container, Doi = r.Doi };
        var dir = Path.GetDirectoryName(path)!;
        var b = Namer.Render(fields, Engine.Naming);
        if (string.Equals(Path.GetFileName(path), b + ".pdf", StringComparison.OrdinalIgnoreCase))
            return new Outcome { Kind = OutcomeKind.Kunye, Path = path, Entry = entry };
        var dest = Path.Combine(dir, UniqueStem(dir, fields, Engine.Naming) + ".pdf");
        lock (gate) reserved.Add(dest);
        try { File.Move(path, dest); }
        catch (Exception e) { return new Outcome { Kind = OutcomeKind.Skipped, Path = path, Note = "error: " + e.Message }; }
        return new Outcome { Kind = OutcomeKind.Renamed, Path = path, To = dest, Note = "manual", Entry = entry };
    }

    Outcome Flagged(string path, string why)
    {
        var name = Path.GetFileName(path);
        if (name.StartsWith(Flag.Prefix)) return new Outcome { Kind = OutcomeKind.Skipped, Path = path, Note = why };
        var dir = Path.GetDirectoryName(path)!;
        var dest = Path.Combine(dir, Flag.Prefix + name);
        int n = 2;
        while (File.Exists(dest)) { dest = Path.Combine(dir, Flag.Prefix + Path.GetFileNameWithoutExtension(path) + $" ({n}).pdf"); n++; }
        try { File.Move(path, dest); } catch { return new Outcome { Kind = OutcomeKind.Skipped, Path = path, Note = why }; }
        return new Outcome { Kind = OutcomeKind.Flagged, Path = path, To = dest, Note = why };
    }

    /// <summary>evaluate: ölçüm modu (dosyaya dokunmaz, benzersizleştirme yok, adlandırılmış dosyayı da çözümler).</summary>
    public async Task<Outcome> Process(string path, bool dryRun = false, bool evaluate = false)
    {
        Outcome Skip(string why) => new() { Kind = OutcomeKind.Skipped, Path = path, Note = why };
        if (!path.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) return Skip("not a PDF");
        var stem0 = Path.GetFileNameWithoutExtension(path);

        if (!evaluate && Engine.AlreadyNamed(stem0))
        {
            if (!Engine.OnlineEnabled) return Skip("already named (online lookup is needed for the reference)");
            var n = Engine.ParseNamed(stem0);
            if (n == null) return Skip("already named");
            var d = Engine.Read(path);
            if (d.Text.Trim().Length == 0) return Skip("text could not be read");
            try
            {
                var o = await Engine.LookupOnline(d);
                if (o?.Ref is { } r && Text_.Squash(o.Authors.FirstOrDefault() ?? "") == Text_.Squash(n.Value.First)
                    && (n.Value.Year == null || o.Year == null || Math.Abs(n.Value.Year.Value - o.Year.Value) <= 1))
                    return new Outcome { Kind = OutcomeKind.Kunye, Path = path, Entry = new RefEntry(r) };
                return Skip("reference not found (publication data did not match the file name)");
            }
            catch (NetworkException) { return new Outcome { Kind = OutcomeKind.Pending, Path = path, Note = PendingReason() }; }
        }

        var data = Engine.Read(path);
        if (data.Text.Trim().Length == 0)
            return evaluate || dryRun ? Skip("text could not be read") : Flagged(path, "text could not be read");
        Found? found;
        try { found = await Engine.Lookup(data); }
        catch (NetworkException) { return new Outcome { Kind = OutcomeKind.Pending, Path = path, Note = PendingReason() }; }
        if (found == null || found.Authors.Count == 0)
        {
            var why = Engine.OnlineEnabled ? "could not resolve, rename manually" : "could not resolve (online lookup is off)";
            return evaluate || dryRun ? Skip(why) : Flagged(path, why);
        }

        var rf = found.Ref;
        if (rf == null && Engine.OnlineEnabled && !evaluate)
        {
            try
            {
                var o = await Engine.LookupOnline(data);
                if (o?.Ref is { } r2 && Text_.Squash(found.Authors.FirstOrDefault() ?? "") == Text_.Squash(o.Authors.FirstOrDefault() ?? "")
                    && (found.Year == null || o.Year == null || Math.Abs(found.Year.Value - o.Year.Value) <= 1)) rf = r2;
            }
            catch { }
        }
        var entry = rf != null ? new RefEntry(rf)
            : new RefEntry(Cite.Minimal(found.Authors, found.Year), "m:" + Text_.Squash(string.Concat(found.Authors)) + "|" + (found.Year ?? 0));
        var fields = new NameFields { Authors = found.Authors, Year = found.Year, Title = rf?.Title ?? "", Journal = rf?.Container ?? "", Doi = rf?.Doi ?? "" };
        var dir = Path.GetDirectoryName(path)!;
        var prefs = evaluate ? new NamingPrefs() : Engine.Naming;
        var b = Namer.Render(fields, prefs);
        if (!evaluate && string.Equals(Path.GetFileName(path), b + ".pdf", StringComparison.OrdinalIgnoreCase))
            return new Outcome { Kind = OutcomeKind.Kunye, Path = path, Entry = entry };
        var stem = evaluate ? b : UniqueStem(dir, fields, prefs);
        var dest = Path.Combine(dir, stem + ".pdf");
        lock (gate) reserved.Add(dest);
        if (!dryRun && !evaluate)
        {
            try { File.Move(path, dest); }
            catch (Exception e) { return Skip("error: " + e.Message); }
        }
        return new Outcome { Kind = OutcomeKind.Renamed, Path = path, To = dest, Note = found.How, Entry = entry };
    }
}

/// <summary>Klasör başına künye listesi: gizli .References.json (tam bilgi) + References.docx (seçili stilde, alfabetik).</summary>
public static class RefStore
{
    public static string RefBase(string folder, string baseName, bool turkish)
    {
        if (File.Exists(Path.Combine(folder, ".Künyeler.json"))) return "Künyeler";
        return string.IsNullOrWhiteSpace(baseName) ? (turkish ? "Künyeler" : "References") : baseName;
    }

    public static List<RefEntry> Load(string folder, string baseName)
    {
        var side = Path.Combine(folder, "." + baseName + ".json");
        try
        {
            if (File.Exists(side)) return JsonSerializer.Deserialize<List<RefEntry>>(File.ReadAllText(side), RefEntry.Json) ?? new();
        }
        catch { }
        return new();
    }

    public static string? Save(List<RefEntry> entries, string folder, string baseName, CiteStyle style)
    {
        var docx = Path.Combine(folder, baseName + ".docx");
        var side = Path.Combine(folder, "." + baseName + ".json");
        try
        {
            if (entries.Count == 0)
            {
                if (File.Exists(docx)) File.Delete(docx);
                if (File.Exists(side)) File.Delete(side);
                return null;
            }
            var rendered = entries.Select(e => (Text: e.Render(style), Flagged: e.NeedsCheck))
                .OrderBy(x => Text_.Fold(x.Text.Replace("*", "")).ToLowerInvariant(), StringComparer.Ordinal).ToList();
            File.WriteAllText(side, JsonSerializer.Serialize(entries, RefEntry.Json));
            try { File.SetAttributes(side, File.GetAttributes(side) | FileAttributes.Hidden); } catch { }
            File.WriteAllBytes(docx, Docx.Build(rendered));
            return docx;
        }
        catch { return null; }
    }

    /// <summary>Künyeyi listeye ekler. Eklediyse .docx yolunu döndürür (zaten varsa null).</summary>
    public static string? Append(RefEntry e, string folder, string baseName, CiteStyle style)
    {
        var list = Load(folder, baseName);
        if (list.Any(x => x.Key == e.Key)) return null;
        list.Add(e);
        return Save(list, folder, baseName, style);
    }

    public static void Remove(string key, string folder, string baseName, CiteStyle style)
    {
        var list = Load(folder, baseName);
        list.RemoveAll(x => x.Key == key || x.Text == key);
        Save(list, folder, baseName, style);
    }
}
