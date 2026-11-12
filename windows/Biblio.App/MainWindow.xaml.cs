using System.Collections.Specialized;
using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Biblio.Core;
using Microsoft.Win32;

namespace Biblio.App;

public partial class MainWindow : Window
{
    readonly AppModel model = new();

    public MainWindow()
    {
        InitializeComponent();
        DataContext = model;
        LogList.ItemsSource = model.Log;
        FolderList.ItemsSource = model.Folders;
        RefList.ItemsSource = model.RefItems;
        model.RefsChanged += () => Dispatcher.Invoke(RefreshRefs);
        model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(AppModel.StatusText) or nameof(AppModel.PendingNote) or nameof(AppModel.NamePreview)) Dispatcher.Invoke(Refresh);
        };
        Title = "Biblio " + (System.Reflection.Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "");
        BuildSettings();
        ApplyLanguage();
        Closing += (_, _) => model.Save();
        if (Environment.GetCommandLineArgs().Contains("--minimized")) WindowState = WindowState.Minimized;
    }

    // MARK: Metinler
    void ApplyLanguage()
    {
        TabRename.Header = Loc.T("Rename");
        TabRefs.Header = Loc.T("References");
        TabSettings.Header = Loc.T("Settings");
        DropText.Text = Loc.T("Drop PDFs or folders here");
        FoldersTitle.Text = Loc.T("Watched folders");
        AddFolderBtn.Content = Loc.T("Add folder…");
        WatchCheck.Content = Loc.T("Watching");
        WatchCheck.IsChecked = model.State.Watching;
        LogTitle.Text = Loc.T("Recent activity");
        ClearBtn.Content = Loc.T("Clear history");
        UndoLastBtn.Content = Loc.T("Undo last");
        RetryBtn.Content = Loc.T("Retry now");
        RefDropTitle.Text = Loc.T("Drop a reference list (.docx or .txt)");
        RefDropHint.Text = Loc.T("Open-access PDFs (article and working-paper versions) are downloaded; for articles that need a subscription the page is opened.");
        RefFolderBtn.Content = Loc.T("Change…");
        RefNextBtn.Content = Loc.T("Open next 5 pages");
        RefClearBtn.Content = Loc.T("Clear history");
        Refresh();
        RefreshRefs();
        // satır etiketleri yeniden çizilsin
        LogList.Items.Refresh();
    }

    void Refresh()
    {
        StatusText.Text = model.StatusText;
        PreviewText.Text = Loc.T("Files are renamed like: {0}", model.NamePreview);
        PendingBanner.Visibility = model.HasPending ? Visibility.Visible : Visibility.Collapsed;
        PendingText.Text = model.HasPending ? Loc.T("{0}. Will retry automatically.", model.PendingNote) : "";
    }

    void RefreshRefs()
    {
        RefFolderText.Text = Loc.T("Download folder: {0}", model.RefFolder);
        RefProgress.Visibility = model.RefBusy ? Visibility.Visible : Visibility.Collapsed;
        RefClearBtn.IsEnabled = model.RefItems.Count > 0 && !model.RefBusy;
        int w = model.RefPagesWaiting;
        RefPagesBanner.Visibility = w > 0 ? Visibility.Visible : Visibility.Collapsed;
        RefPagesText.Text = Loc.T("{0} article pages are waiting to be opened (to download with your subscription)", w);
        RefList.Items.Refresh();
    }

    // MARK: Kaynakça sekmesi
    static bool IsRefFile(string p) => p.EndsWith(".docx", StringComparison.OrdinalIgnoreCase) || p.EndsWith(".txt", StringComparison.OrdinalIgnoreCase);
    void RefDrop_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        RefDropZone.Background = System.Windows.Media.Brushes.AliceBlue;
        e.Handled = true;
    }
    void RefDrop_DragLeave(object sender, DragEventArgs e) => RefDropZone.Background = (System.Windows.Media.Brush)new System.Windows.Media.BrushConverter().ConvertFromString("#F3F6F9")!;
    void RefDrop_Drop(object sender, DragEventArgs e)
    {
        RefDrop_DragLeave(sender, e);
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths && paths.FirstOrDefault(IsRefFile) is string f) model.LoadRefFile(f);
    }
    void RefDrop_Click(object sender, MouseButtonEventArgs e)
    {
        var dlg = new OpenFileDialog { Filter = "Reference list (*.docx;*.txt)|*.docx;*.txt" };
        if (dlg.ShowDialog(this) == true) model.LoadRefFile(dlg.FileName);
    }
    void RefFolder_Click(object s, RoutedEventArgs e)
    {
        var dlg = new OpenFolderDialog();
        if (dlg.ShowDialog(this) == true) model.RefFolder = dlg.FolderName;
    }
    void RefNext_Click(object s, RoutedEventArgs e) => model.OpenNextPages(5);
    void RefClear_Click(object s, RoutedEventArgs e) => model.ClearRefItems();
    void RefOpenPage_Click(object s, RoutedEventArgs e) { if ((s as FrameworkElement)?.Tag is RefItem it) model.OpenPage(it); }
    void RefRemove_Click(object s, RoutedEventArgs e) { if ((s as FrameworkElement)?.Tag is RefItem it) model.RemoveRefItem(it); }

    // MARK: Bırakma alanı
    void DropZone_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        DropZone.Background = System.Windows.Media.Brushes.AliceBlue;
        e.Handled = true;
    }
    void DropZone_DragLeave(object sender, DragEventArgs e) => DropZone.Background = (System.Windows.Media.Brush)new System.Windows.Media.BrushConverter().ConvertFromString("#F3F6F9")!;
    void DropZone_Drop(object sender, DragEventArgs e)
    {
        DropZone_DragLeave(sender, e);
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths) model.HandleDrop(paths);
    }

    // MARK: Düğmeler
    void AddFolder_Click(object s, RoutedEventArgs e)
    {
        var dlg = new OpenFolderDialog();
        if (dlg.ShowDialog(this) == true) model.AddFolder(dlg.FolderName);
    }
    public string ResetHelp => Loc.T("Start a new reference list for this folder (the current .docx is deleted)");
    void ResetList_Click(object s, RoutedEventArgs e)
    {
        if ((s as FrameworkElement)?.Tag is not string p) return;
        if (!model.HasRefList(p)) { MessageBox.Show(this, Loc.T("There is no Biblio reference list in this folder."), "Biblio"); return; }
        if (MessageBox.Show(this, Loc.T("The current reference list (.docx) of this folder will be deleted and the next references start a fresh list. PDFs are not touched. Continue?"), Loc.T("Start a new reference list for this folder?"), MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
            model.ResetRefList(p);
    }
    void RemoveFolder_Click(object s, RoutedEventArgs e) { if ((s as FrameworkElement)?.Tag is string p) model.RemoveFolder(p); }
    void Watch_Click(object s, RoutedEventArgs e) => model.SetWatching(WatchCheck.IsChecked == true);
    void Retry_Click(object s, RoutedEventArgs e) => model.RetryNow();
    void Clear_Click(object s, RoutedEventArgs e) => model.ClearLog();
    void UndoLast_Click(object s, RoutedEventArgs e) { model.UndoLast(); LogList.Items.Refresh(); }
    void Undo_Click(object s, RoutedEventArgs e) { if ((s as FrameworkElement)?.Tag is LogEntry l) { model.Undo(l); LogList.Items.Refresh(); } }
    void RemoveRow_Click(object s, RoutedEventArgs e) { if ((s as FrameworkElement)?.Tag is LogEntry l) model.RemoveLogEntry(l); }
    async void Enter_Click(object s, RoutedEventArgs e)
    {
        if ((s as FrameworkElement)?.Tag is not LogEntry l) return;
        var w = new ManualWindow(model, l.OldPath) { Owner = this };
        w.ShowDialog();
        LogList.Items.Refresh();
        await Task.CompletedTask;
    }

    // MARK: Ayarlar sekmesi (kodla kurulur: dil değişince yeniden çizilir)
    void BuildSettings()
    {
        var p = SettingsPanel;
        p.Children.Clear();
        var st = model.State;

        GroupBox Group(string title, params UIElement[] items)
        {
            var sp = new StackPanel { Margin = new Thickness(8) };
            foreach (var i in items) sp.Children.Add(i);
            return new GroupBox { Header = Loc.T(title), Content = sp, Margin = new Thickness(0, 0, 0, 12) };
        }
        TextBlock Label(string t, bool small = false) => new() { Text = Loc.T(t), Margin = new Thickness(0, 6, 0, 2), TextWrapping = TextWrapping.Wrap, Foreground = small ? System.Windows.Media.Brushes.Gray : System.Windows.Media.Brushes.Black, FontSize = small ? 11.5 : 12.5 };
        CheckBox Check(string t, bool val, Action<bool> set) { var c = new CheckBox { Content = Loc.T(t), IsChecked = val, Margin = new Thickness(0, 4, 0, 4) }; c.Click += (_, _) => { set(c.IsChecked == true); model.SettingsChanged(); }; return c; }
        TextBox Text(string val, Action<string> set, double width = double.NaN) { var t = new TextBox { Text = val, Width = width, HorizontalAlignment = HorizontalAlignment.Left, MinWidth = 120 }; t.LostFocus += (_, _) => { set(t.Text); model.SettingsChanged(); Preview(); }; return t; }
        ComboBox Combo(IEnumerable<(string Id, string Label)> items, string current, Action<string> set)
        {
            var list = items.ToList();
            var c = new ComboBox { Width = 260, HorizontalAlignment = HorizontalAlignment.Left, DisplayMemberPath = "Label", SelectedValuePath = "Id", ItemsSource = list.Select(i => new { i.Id, i.Label }).ToList() };
            c.SelectedValue = current;
            c.SelectionChanged += (_, _) => { if (c.SelectedValue is string v) { set(v); model.SettingsChanged(); Preview(); } };
            return c;
        }
        var preview = new TextBlock { FontFamily = new System.Windows.Media.FontFamily("Consolas"), Margin = new Thickness(0, 6, 0, 0) };
        void Preview() => preview.Text = Loc.T("Preview: {0}", model.NamePreview);

        // Genel
        var lang = Combo(new[] { ("en", "English"), ("tr", "Türkçe") }, st.Language, v => { st.Language = v; });
        lang.SelectionChanged += (_, _) => { BuildSettings(); ApplyLanguage(); };
        var startup = new CheckBox { Content = Loc.T("Start at login"), IsChecked = model.LaunchAtLogin, Margin = new Thickness(0, 4, 0, 4) };
        startup.Click += (_, _) => model.LaunchAtLogin = startup.IsChecked == true;
        p.Children.Add(Group("General", Label("Language"), lang, startup,
            Check("Also process the PDFs already inside a folder when it is added", st.ProcessExisting, v => st.ProcessExisting = v)));

        // Dosya adı
        var presets = Namer.Presets.Select(x => (x.Template, st.Language == "tr" ? x.Tr : x.En)).ToList();
        var presetBox = Combo(presets.Select(x => (x.Item1, x.Item2)), Namer.Presets.Any(x => x.Template == st.Template) ? st.Template : "", v => st.Template = v);
        var templateBox = Text(st.Template, v => st.Template = v, 320);
        presetBox.SelectionChanged += (_, _) => templateBox.Text = st.Template;
        var andBox = Combo(new[] { ("&", "&"), ("and", "and"), ("ve", "ve"), (",", ",") }, st.AndWord, v => st.AndWord = v);
        p.Children.Add(Group("File naming", Label("Preset"), presetBox, Label("Template"), templateBox,
            Label("Title length limit"), Text(st.TitleMax.ToString(), v => { if (int.TryParse(v, out var n) && n > 5) st.TitleMax = n; }, 60),
            Label("Authors written before “et al”"), Text(st.MaxAuthors.ToString(), v => { if (int.TryParse(v, out var n) && n > 0) st.MaxAuthors = n; }, 60),
            Label("Author separator"), andBox,
            Check("Keep accented letters (Turkish characters etc.)", st.KeepAccents, v => st.KeepAccents = v), preview));
        Preview();

        // Künye listesi
        var styles = Enum.GetValues<CiteStyle>().Select(x => (x.ToString(), Cite.Label(x)));
        p.Children.Add(Group("Reference list",
            Check("Write a reference list (.docx) next to the PDFs", st.WriteApa, v => st.WriteApa = v),
            Label("Citation style"), Combo(styles, st.CiteStyle, v => { st.CiteStyle = v; model.SettingsChanged(); model.RegenerateRefFiles(); }),
            Label("File name of the list"), Text(st.RefFileName, v => st.RefFileName = v, 200)));

        // Arama
        var key = Text(st.OpenAlexKey ?? "", v => st.OpenAlexKey = v.Trim().Length == 0 ? null : v.Trim(), 320);
        p.Children.Add(Group("Lookup",
            Check("Look up the publication online (Crossref, OpenAlex). Only the DOI or a few title lines are sent; the PDF is never uploaded.", st.OnlineLookup, v => st.OnlineLookup = v),
            Label("OpenAlex API key (optional, free)"), key,
            Check("Guess from the page text when nothing is found (less reliable)", st.GuessMode, v => st.GuessMode = v)));

        // Geçmiş
        var clear = new Button { Content = Loc.T("Clear history"), HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(12, 3, 12, 3), Margin = new Thickness(0, 6, 0, 0) };
        clear.Click += (_, _) => model.ClearLog();
        p.Children.Add(Group("History", Label("Clearing history only empties the lists you see; files and reference lists are not touched, but cleared activity can no longer be undone.", true), clear));
    }
}
