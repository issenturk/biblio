using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Text.Json;
using System.Windows;
using System.Windows.Threading;
using Biblio.Core;
using Microsoft.Win32;

namespace Biblio.App;

public class AppModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    void Notify(string n) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));

    public AppState State { get; private set; } = new();
    public ObservableCollection<LogEntry> Log { get; } = new();
    public ObservableCollection<string> Folders { get; } = new();

    readonly Processor processor = new();
    readonly Dictionary<string, FileSystemWatcher> watchers = new();
    readonly HashSet<string> inFlight = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, DateTime> pendingUntil = new(StringComparer.OrdinalIgnoreCase);
    readonly SemaphoreSlim slots = new(4);
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(45) };
    readonly DispatcherTimer debounce = new() { Interval = TimeSpan.FromSeconds(2) };
    int busy;
    bool needsRescan;

    static string StatePath
    {
        get
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Biblio");
            Directory.CreateDirectory(dir);
            return Path.Combine(dir, "state.json");
        }
    }

    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull };

    // MARK: Görünen durum
    string pendingNote = "";
    public string PendingNote { get => pendingNote; set { pendingNote = value; Notify(nameof(PendingNote)); Notify(nameof(HasPending)); } }
    public bool HasPending => pendingNote.Length > 0;
    public string StatusText => busy > 0 ? Loc.T("Working…") : Loc.T("Idle");
    public string NamePreview => Namer.Render(new NameFields { Authors = new() { "Garcia Vaquero", "Becker", "Murphy" }, Year = 1988, Title = "A theory of rational addiction", Journal = "Journal of Political Economy" }, Engine.Naming);

    public AppModel()
    {
        try { if (File.Exists(StatePath)) State = JsonSerializer.Deserialize<AppState>(File.ReadAllText(StatePath), Json) ?? new(); } catch { State = new(); }
        foreach (var e in State.Log) Log.Add(e);
        foreach (var f in State.Folders) Folders.Add(f);
        Engine.Ocr = SafeOcr();
        ApplySettings();
        RebuildWatchers();
        timer.Tick += (_, _) => { ScanAll(); RetryDue(); };
        timer.Start();
        debounce.Tick += (_, _) => { debounce.Stop(); ScanAll(); };
        ScanAll();
        RegenerateRefFiles();
    }

    static IOcr? SafeOcr() { try { return new WindowsOcr(); } catch { return null; } }

    public void ApplySettings()
    {
        Engine.OpenAlexKey = State.OpenAlexKey;
        Engine.OnlineEnabled = State.OnlineLookup;
        Engine.GuessEnabled = State.GuessMode;
        Engine.Naming = new NamingPrefs { Template = State.Template, TitleMax = State.TitleMax, MaxAuthors = State.MaxAuthors, AndWord = State.AndWord, EtAl = State.EtAl, KeepAccents = State.KeepAccents };
        Engine.Style = Enum.TryParse<CiteStyle>(State.CiteStyle, true, out var s) ? s : CiteStyle.Apa;
        Loc.Lang = State.Language;
        Notify(nameof(NamePreview));
    }

    public void Save()
    {
        State.Log = Log.Take(300).ToList();
        State.Folders = Folders.ToList();
        try { File.WriteAllText(StatePath, JsonSerializer.Serialize(State, Json)); } catch { }
    }

    public void SettingsChanged() { ApplySettings(); Save(); }

    // MARK: Klasörler
    public void AddFolder(string path)
    {
        if (!Directory.Exists(path) || Folders.Contains(path, StringComparer.OrdinalIgnoreCase)) return;
        Folders.Add(path);
        foreach (var k in State.Skipped.Keys.Where(k => string.Equals(Path.GetDirectoryName(k), path, StringComparison.OrdinalIgnoreCase)).ToList()) State.Skipped.Remove(k);
        Save(); RebuildWatchers();
        if (State.ProcessExisting) ScanFolder(path);
    }

    public void RemoveFolder(string path) { Folders.Remove(path); Save(); RebuildWatchers(); }

    public void RebuildWatchers()
    {
        foreach (var w in watchers.Values) w.Dispose();
        watchers.Clear();
        if (!State.Watching) return;
        foreach (var f in Folders)
        {
            if (!Directory.Exists(f)) continue;
            try
            {
                var w = new FileSystemWatcher(f, "*.pdf") { NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size, EnableRaisingEvents = true };
                void Hit(object? s, FileSystemEventArgs e) => Application.Current?.Dispatcher.BeginInvoke(() => { debounce.Stop(); debounce.Start(); });
                w.Created += Hit; w.Renamed += (s, e) => Hit(s, e); w.Changed += Hit;
                watchers[f] = w;
            }
            catch { }
        }
    }

    public void SetWatching(bool on) { State.Watching = on; Save(); RebuildWatchers(); Notify(nameof(State)); }

    // MARK: Tarama
    static double Mtime(string p) { try { return new DateTimeOffset(File.GetLastWriteTimeUtc(p)).ToUnixTimeMilliseconds() / 1000.0; } catch { return 0; } }
    static long Size(string p) { try { return new FileInfo(p).Length; } catch { return 0; } }

    IEnumerable<string> Pdfs(string dir)
    {
        try { return Directory.GetFiles(dir, "*.pdf").Where(f => !Path.GetFileName(f).StartsWith("~$")).OrderBy(f => f, StringComparer.OrdinalIgnoreCase).ToList(); }
        catch { return Array.Empty<string>(); }
    }

    public void ScanAll() { foreach (var f in Folders.ToList()) ScanFolder(f); }

    public void ScanFolder(string folder)
    {
        if (busy > 0) { needsRescan = true; return; }
        bool wantKunye = State.WriteApa && Engine.OnlineEnabled;
        var files = Pdfs(folder).Where(f =>
        {
            if (pendingUntil.TryGetValue(f, out var t) && t > DateTime.Now) return false;
            var m = Mtime(f);
            if (State.NamedFiles.TryGetValue(f, out var nm) && nm == m) return false;
            if (Engine.AlreadyNamed(Path.GetFileNameWithoutExtension(f)))
                return wantKunye && !(State.KunyeDone.TryGetValue(f, out var kd) && kd == m);
            if (State.Skipped.TryGetValue(f, out var sk) && sk == m) return false;
            return true;
        }).ToList();
        if (files.Count > 0) _ = Run(files, force: false);
    }

    public void HandleDrop(IEnumerable<string> paths)
    {
        var files = new List<string>();
        foreach (var p in paths)
        {
            if (Directory.Exists(p)) files.AddRange(Pdfs(p));
            else if (p.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) files.Add(p);
        }
        if (files.Count == 0) { AddLog(new LogEntry { Status = Status.Skipped, OldPath = paths.FirstOrDefault() ?? "", Note = "no PDF found in the dropped item" }); return; }
        foreach (var f in files) { State.Skipped.Remove(f); State.NamedFiles.Remove(f); State.KunyeDone.Remove(f); pendingUntil.Remove(f); }
        _ = Run(files, force: true);
    }

    public void RetryNow()
    {
        pendingUntil.Clear();
        Engine.OpenAlexCooldownUntil = DateTime.MinValue;
        PendingNote = "";
        foreach (var e in Log.Where(l => l.Status == Status.Pending).ToList()) Log.Remove(e);
        ScanAll();
    }

    void RetryDue() { if (pendingUntil.Count > 0 && !pendingUntil.Values.Any(t => t > DateTime.Now)) { PendingNote = ""; } }

    // MARK: İşlem
    async Task Run(List<string> files, bool force)
    {
        var todo = files.Where(f => inFlight.Add(f)).ToList();
        if (todo.Count == 0) return;
        busy += todo.Count; Notify(nameof(StatusText));
        await Task.WhenAll(todo.Select(f => HandleOne(f, force)));
        Save();
        if (busy == 0 && needsRescan) { needsRescan = false; ScanAll(); }
    }

    async Task HandleOne(string f, bool force)
    {
        await slots.WaitAsync();
        try
        {
            if (!force)
            {
                var s1 = Size(f); var t = Mtime(f);
                await Task.Delay(2000);
                if (Size(f) != s1 || (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0) - t < 2) { return; }   // indirme sürüyor
            }
            var outcome = await Task.Run(() => processor.Process(f));
            Finish(outcome);
        }
        catch (Exception e) { AddLog(new LogEntry { Status = Status.Skipped, OldPath = f, Note = "error: " + e.Message }); }
        finally { slots.Release(); inFlight.Remove(f); busy--; Notify(nameof(StatusText)); }
    }

    string RefBase(string folder) => RefStore.RefBase(folder, State.RefFileName, State.Language == "tr");

    void Finish(Outcome o)
    {
        switch (o.Kind)
        {
            case OutcomeKind.Renamed:
                {
                    pendingUntil.Remove(o.Path);
                    RemoveStale(o.Path);
                    State.NamedFiles[o.To!] = Mtime(o.To!);
                    var e = new LogEntry { Status = Status.Renamed, OldPath = o.Path, NewPath = o.To, Note = o.Note };
                    if (State.WriteApa && o.Entry != null) { e.Apa = o.Entry.Key; e.ApaFile = AppendEntry(o.Entry, Path.GetDirectoryName(o.To!)!); }
                    AddLog(e);
                    break;
                }
            case OutcomeKind.Kunye:
                {
                    pendingUntil.Remove(o.Path);
                    RemoveStale(o.Path);
                    string? file = State.WriteApa && o.Entry != null ? AppendEntry(o.Entry, Path.GetDirectoryName(o.Path)!) : null;
                    State.KunyeDone[o.Path] = Mtime(o.Path); State.NamedFiles[o.Path] = Mtime(o.Path);
                    AddLog(new LogEntry { Status = Status.Kunye, OldPath = o.Path, Note = file == null ? "reference was already in the reference list" : "reference added to the reference list", Apa = o.Entry?.Key, ApaFile = file });
                    break;
                }
            case OutcomeKind.Flagged:
                RemoveStale(o.Path); RemoveStale(o.To!);
                State.Skipped[o.To!] = Mtime(o.To!);
                AddLog(new LogEntry { Status = Status.Skipped, OldPath = o.To!, Note = Loc.T("{0}. File renamed to “{1}” so it appears at the top of the folder.", Loc.T(o.Note), Path.GetFileName(o.To!)) });
                break;
            case OutcomeKind.Skipped:
                if (Engine.AlreadyNamed(Path.GetFileNameWithoutExtension(o.Path))) State.KunyeDone[o.Path] = Mtime(o.Path);
                else State.Skipped[o.Path] = Mtime(o.Path);
                AddLog(new LogEntry { Status = Status.Skipped, OldPath = o.Path, Note = o.Note });
                break;
            case OutcomeKind.Pending:
                pendingUntil[o.Path] = DateTime.Now.AddMinutes(5);
                PendingNote = Loc.T(o.Note);
                if (!(Log.FirstOrDefault() is { Status: Status.Pending } first && first.OldPath == o.Path))
                    AddLog(new LogEntry { Status = Status.Pending, OldPath = o.Path, Note = Loc.T("waiting: {0}", Loc.T(o.Note)) });
                break;
        }
        Save();
    }

    void RemoveStale(string path)
    {
        foreach (var e in Log.Where(l => (l.Status == Status.Pending || l.Status == Status.Skipped) && string.Equals(l.OldPath, path, StringComparison.OrdinalIgnoreCase)).ToList()) Log.Remove(e);
    }

    void AddLog(LogEntry e)
    {
        Log.Insert(0, e);
        while (Log.Count > 300) Log.RemoveAt(Log.Count - 1);
    }

    // MARK: Künye listesi
    string? AppendEntry(RefEntry e, string folder) => RefStore.Append(e, folder, RefBase(folder), Engine.Style);

    public void RegenerateRefFiles()
    {
        var folders = Folders.ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var e in Log) if (e.ApaFile != null) folders.Add(Path.GetDirectoryName(e.ApaFile)!);
        foreach (var f in folders)
        {
            if (!Directory.Exists(f)) continue;
            var b = RefBase(f);
            var list = RefStore.Load(f, b);
            if (list.Count > 0) RefStore.Save(list, f, b, Engine.Style);
        }
    }

    // MARK: Geri alma ve geçmiş
    public void Undo(LogEntry e)
    {
        if (e.Status == Status.Kunye)
        {
            RemoveEntry(e); Mark(e, Status.Undone); return;
        }
        if (e.Status != Status.Renamed || e.NewPath == null) return;
        if (!File.Exists(e.NewPath) || File.Exists(e.OldPath)) return;
        try
        {
            File.Move(e.NewPath, e.OldPath);
            State.NamedFiles.Remove(e.NewPath);
            RemoveEntry(e);
            Mark(e, Status.Undone);
            State.Skipped[e.OldPath] = Mtime(e.OldPath);   // hemen tekrar adlandırma
            Save();
        }
        catch { }
    }

    public void UndoLast() { var e = Log.FirstOrDefault(l => l.Status == Status.Renamed); if (e != null) Undo(e); }

    void Mark(LogEntry e, Status s)
    {
        int i = Log.IndexOf(e);
        if (i < 0) return;
        e.Status = s;
        Log[i] = e; Save();
    }

    void RemoveEntry(LogEntry e)
    {
        if (e.ApaFile == null || e.Apa == null) return;
        var folder = Path.GetDirectoryName(e.ApaFile)!;
        RefStore.Remove(e.Apa, folder, Path.GetFileNameWithoutExtension(e.ApaFile), Engine.Style);
    }

    public void ClearLog() { Log.Clear(); PendingNote = ""; Save(); }
    public void RemoveLogEntry(LogEntry e) { Log.Remove(e); Save(); }

    // MARK: Elle giriş
    public async Task<string?> SubmitManual(string path, ManualForm f)
    {
        var people = RefParse.ParsePeople(f.Authors);
        if (people.Count == 0) return Loc.T("Enter at least one author");
        int? year = null;
        var yt = f.Year.Trim();
        if (yt.Length > 0)
        {
            if (!int.TryParse(yt, out var y) || y < 1000 || y > Engine.CurrentYear + 1) return Loc.T("The year must be four digits (or leave it empty)");
            year = y;
        }
        var r = new Ref { Authors = people, Year = year, Title = f.Title.Trim(), Container = f.Container.Trim(), Volume = f.Volume.Trim(), Issue = f.Issue.Trim(), Pages = f.Pages.Trim(), Doi = f.Doi.Trim(), Publisher = f.Publisher.Trim(), Type = f.Type };
        var entry = f.Ready.Trim().Length > 0 ? new RefEntry(f.Ready.Trim()) : new RefEntry(r);
        var o = await Task.Run(() => processor.RenameManual(path, people.Select(p => p.Family).ToList(), year, r, entry));
        if (o.Kind == OutcomeKind.Skipped) return Loc.T(o.Note);
        Finish(o);
        return null;
    }

    public async Task<ManualForm> PrefillManual(string path)
    {
        var f = new ManualForm();
        await Task.Run(() =>
        {
            var d = Engine.Read(path);
            var first = d.Pages.FirstOrDefault() ?? "";
            f.Doi = Text_.Matches(@"10\.\d{4,9}/[^\s""<>]+", d.Text).FirstOrDefault()?.Trim(".,;)]}".ToCharArray()) ?? "";
            f.Year = Engine.GuessYear(first)?.ToString() ?? "";
            var g = Engine.LocalGuess(first);
            f.Authors = g == null ? "" : string.Join("\n", g.Value.Item1);
        });
        return f;
    }

    // MARK: Kaynakça: listedeki eserleri bul, açık erişimlileri indir, diğerlerinin sayfasını aç
    public ObservableCollection<RefItem> RefItems { get; } = new();
    bool refBusy;
    public bool RefBusy { get => refBusy; private set { refBusy = value; Notify(nameof(RefBusy)); } }
    public int RefPagesWaiting => RefItems.Count(i => i.Page != null && !i.Opened);
    public event Action? RefsChanged;

    public string RefFolder
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(State.RefFolder)) return State.RefFolder!;
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", State.Language == "tr" ? "Kaynakça" : "References");
        }
        set { State.RefFolder = value; Save(); Notify(nameof(RefFolder)); RefsChanged?.Invoke(); }
    }

    public void LoadRefFile(string path)
    {
        if (RefBusy) return;
        var entries = Bibliography.Entries(path);
        RefItems.Clear();
        if (entries.Count == 0)
        {
            RefItems.Add(new RefItem { Text = Loc.T("{0}: no reference lines found (each line needs a year)", Path.GetFileName(path)), Status = RefStatus.Failed });
            RefsChanged?.Invoke();
            return;
        }
        foreach (var e in entries) RefItems.Add(new RefItem { Text = e });
        RefBusy = true;
        var items = RefItems.ToList();
        RefsChanged?.Invoke();
        _ = Task.Run(async () =>
        {
            using var gate = new SemaphoreSlim(3);
            await Task.WhenAll(items.Select(async it =>
            {
                await gate.WaitAsync();
                try { await ProcessRef(it); } finally { gate.Release(); }
            }));
            await Application.Current.Dispatcher.InvokeAsync(() => { RefBusy = false; RefsChanged?.Invoke(); });
        });
    }

    static void UI(Action a) => Application.Current.Dispatcher.Invoke(a);

    async Task ProcessRef(RefItem item)
    {
        UI(() => item.Status = RefStatus.Working);
        try
        {
            var r = await Bibliography.Resolve(item.Text);
            if (r == null) { UI(() => { item.Status = RefStatus.NotFound; item.Note = Loc.T("No matching record found in Crossref"); }); return; }
            var folder = RefFolder;
            var shortName = string.Join("-", Text_.Fold(r.Title).Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(4));
            var got = new List<string>(); var notes = new List<string>(); var hashes = new HashSet<string>();
            bool published = false;
            foreach (var v in r.Versions)
            {
                if (v.Pdf == null) continue;
                var f = await Bibliography.DownloadPdf(v.Pdf, folder, $"ref-{shortName}-{(v.IsPublished ? "article" : "wp")}");
                if (f == null) continue;
                var fp = Bibliography.Fingerprint(f);
                if (!hashes.Add(fp)) { try { File.Delete(f); } catch { } if (v.IsPublished) published = true; continue; }   // aynı dosya zaten indirildi
                got.Add(f); notes.Add(Loc.T("{0} downloaded", Loc.T(v.Label))); if (v.IsPublished) published = true;
            }
            if (got.Count > 0) await Application.Current.Dispatcher.InvokeAsync(() => _ = Run(got, force: true));   // indirilenler Biblio ile adlandırılır, künyeleri eklenir
            var page = published ? null : r.Landing;
            var note = string.Join(", ", notes);
            if (page != null) note += (note.Length == 0 ? "" : "; ") + Loc.T("no open PDF for the article: open the page and download it with your subscription");
            if (r.OpenAlexDown) note += " " + Loc.T("(OpenAlex unreachable: working-paper versions were not searched)");
            var status = got.Count > 0 ? RefStatus.Done : (page != null ? RefStatus.PageOnly : RefStatus.NotFound);
            if (got.Count == 0 && page == null) note = Loc.T("no downloadable version or page found");
            UI(() => { item.Title = r.Title; item.Page = page; item.Note = note; item.Status = status; RefsChanged?.Invoke(); });
        }
        catch (Exception)
        {
            var issue = Engine.LastIssue.Length == 0 ? Loc.T("network/limit problem") : Engine.LastIssue;
            UI(() => { item.Status = RefStatus.Failed; item.Note = issue; });
        }
    }

    public void OpenPage(RefItem item)
    {
        if (item.Page == null) return;
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(item.Page) { UseShellExecute = true }); } catch { }
        item.Opened = true; RefsChanged?.Invoke();
    }

    public void OpenNextPages(int n = 5)
    {
        int c = 0;
        foreach (var it in RefItems.Where(i => i.Page != null && !i.Opened).ToList())
        {
            if (c++ >= n) break;
            OpenPage(it);
        }
    }

    public void ClearRefItems() { if (!RefBusy) { RefItems.Clear(); RefsChanged?.Invoke(); } }
    public void RemoveRefItem(RefItem it) { if (!RefBusy) { RefItems.Remove(it); RefsChanged?.Invoke(); } }

    // MARK: Oturum açılışında başlat
    public bool LaunchAtLogin
    {
        get { using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); return k?.GetValue("Biblio") != null; }
        set
        {
            using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true);
            if (k == null) return;
            if (value) k.SetValue("Biblio", $"\"{Environment.ProcessPath}\"");
            else k.DeleteValue("Biblio", false);
            Notify(nameof(LaunchAtLogin));
        }
    }
}

public class ManualForm
{
    public string Authors = "", Year = "", Type = "journal-article", Title = "", Container = "", Volume = "", Issue = "", Pages = "", Doi = "", Publisher = "", Ready = "";
}
