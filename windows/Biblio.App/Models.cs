using System.ComponentModel;
using Biblio.Core;

namespace Biblio.App;

public enum Status { Renamed, Skipped, Undone, Pending, Kunye }

public class LogEntry
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Status Status { get; set; }
    public DateTime Date { get; set; } = DateTime.Now;
    public string OldPath { get; set; } = "";
    public string? NewPath { get; set; }
    public string Note { get; set; } = "";
    public string? Apa { get; set; }        // künye anahtarı
    public string? ApaFile { get; set; }

    // Görünüm
    public string OldName => Path.GetFileName(OldPath);
    public string NewName => NewPath == null ? "" : Path.GetFileName(NewPath);
    public bool HasNew => NewPath != null;
    public string Icon => Status switch { Status.Renamed => "✔", Status.Kunye => "✔", Status.Undone => "↶", Status.Pending => "⏳", _ => "⚠" };
    public System.Windows.Media.Brush IconBrush => (System.Windows.Media.Brush)new System.Windows.Media.BrushConverter().ConvertFromString(IconColor)!;
    public string EnterLabel => Loc.T("Enter details…");
    public string UndoLabel => Loc.T("Undo");
    public string RemoveHelp => Loc.T("Remove this row from the list (files and the reference list are not touched)");
    public string IconColor => Status is Status.Renamed or Status.Kunye ? "#2E7D32" : Status == Status.Skipped ? "#B26A00" : "#777777";
    public string Detail
    {
        get
        {
            if (NewPath != null)
            {
                bool verified = new[] { "cover", "filename", "id", "doi", "isbn", "title", "working-paper", "manual" }.Contains(Note);
                return verified ? Loc.T("source: {0}", Loc.T(Note)) : Loc.T("source: {0} (guess, please check)", Loc.T(Note));
            }
            return Loc.T(Note);
        }
    }
    public bool CanUndo => Status == Status.Renamed || (Status == Status.Kunye && ApaFile != null);
    public bool CanEnter => Status == Status.Skipped && OldPath.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) && File.Exists(OldPath);
}

public class AppState
{
    public List<string> Folders { get; set; } = new();
    public bool Watching { get; set; } = true;
    public bool ProcessExisting { get; set; } = true;
    public string? OpenAlexKey { get; set; }
    public bool OnlineLookup { get; set; } = true;
    public bool GuessMode { get; set; }
    public bool WriteApa { get; set; } = true;
    public string Language { get; set; } = "en";
    public string Template { get; set; } = "{Author} - {Year}";
    public int TitleMax { get; set; } = 60;
    public int MaxAuthors { get; set; } = 2;
    public string AndWord { get; set; } = "&";
    public string EtAl { get; set; } = "et al";
    public bool KeepAccents { get; set; }
    public string CiteStyle { get; set; } = "Apa";
    public string RefFileName { get; set; } = "";
    public string? RefFolder { get; set; }
    public Dictionary<string, double> Skipped { get; set; } = new();
    public Dictionary<string, double> NamedFiles { get; set; } = new();
    public Dictionary<string, double> KunyeDone { get; set; } = new();
    public List<LogEntry> Log { get; set; } = new();
}

public enum RefStatus { Waiting, Working, Done, PageOnly, NotFound, Failed }

/// <summary>Kaynakça sekmesindeki bir kaynak satırı.</summary>
public class RefItem : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    void N() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));

    public Guid Id { get; } = Guid.NewGuid();
    public string Text { get; set; } = "";
    string title = "", note = "";
    RefStatus status = RefStatus.Waiting;
    string? page;
    bool opened;

    public string Title { get => title; set { title = value; N(); } }
    public string Note { get => note; set { note = value; N(); } }
    public RefStatus Status { get => status; set { status = value; N(); } }
    public string? Page { get => page; set { page = value; N(); } }
    public bool Opened { get => opened; set { opened = value; N(); } }

    public string Display => Title.Length == 0 ? Text : Title;
    public bool HasNote => Note.Length > 0;
    public bool HasPage => Page != null;
    public string PageLabel => Opened ? Loc.T("Reopen") : Loc.T("Open page");
    public string Icon => Status switch { RefStatus.Done => "✔", RefStatus.Working => "⟳", RefStatus.PageOnly => "↗", RefStatus.NotFound => "?", RefStatus.Failed => "⚠", _ => "…" };
    public System.Windows.Media.Brush IconBrush => (System.Windows.Media.Brush)new System.Windows.Media.BrushConverter().ConvertFromString(
        Status switch { RefStatus.Done => "#2E7D32", RefStatus.PageOnly => "#B26A00", RefStatus.Failed => "#C62828", _ => "#777777" })!;
}
