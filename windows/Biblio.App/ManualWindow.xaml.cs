using System.Windows;
using System.Windows.Controls;
using Biblio.Core;

namespace Biblio.App;

public partial class ManualWindow : Window
{
    readonly AppModel model;
    readonly string path;
    readonly TextBox authors = new() { AcceptsReturn = true, Height = 62, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    readonly TextBox year = new() { Width = 90, HorizontalAlignment = HorizontalAlignment.Left };
    readonly ComboBox type = new() { Width = 220 };
    readonly TextBox title = new(), container = new(), volume = new(), issue = new(), pages = new(), doi = new(), publisher = new();
    readonly TextBox ready = new() { AcceptsReturn = true, Height = 62, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, TextWrapping = TextWrapping.Wrap };
    readonly TextBlock error = new() { Foreground = System.Windows.Media.Brushes.Red, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };

    public ManualWindow(AppModel model, string path)
    {
        InitializeComponent();
        this.model = model; this.path = path;
        Title = Loc.T("Enter details manually");
        var types = new[] { ("journal-article", "Journal article"), ("book", "Book"), ("book-chapter", "Book chapter"), ("report", "Report / working paper") };
        type.ItemsSource = types.Select(t => new { Id = t.Item1, Label = Loc.T(t.Item2) }).ToList();
        type.DisplayMemberPath = "Label"; type.SelectedValuePath = "Id"; type.SelectedValue = "journal-article";

        TextBlock L(string t, bool small = true) => new() { Text = Loc.T(t), FontSize = small ? 11.5 : 12.5, Foreground = System.Windows.Media.Brushes.Gray, Margin = new Thickness(0, 6, 0, 2), TextWrapping = TextWrapping.Wrap };
        StackPanel Field(string label, TextBox box) { var sp = new StackPanel(); sp.Children.Add(L(label)); sp.Children.Add(box); return sp; }
        Grid Row(params UIElement[] items)
        {
            var g = new Grid();
            for (int i = 0; i < items.Length; i++) { g.ColumnDefinitions.Add(new ColumnDefinition()); Grid.SetColumn(items[i], i); if (i > 0 && items[i] is FrameworkElement fe) fe.Margin = new Thickness(10, 0, 0, 0); g.Children.Add(items[i]); }
            return g;
        }

        Root.Children.Add(new TextBlock { Text = Loc.T("Enter details manually"), FontSize = 16, FontWeight = FontWeights.SemiBold });
        Root.Children.Add(new TextBlock { Text = System.IO.Path.GetFileName(path), Foreground = System.Windows.Media.Brushes.Gray, TextTrimming = TextTrimming.CharacterEllipsis });
        Root.Children.Add(L("Authors (one per line: Family, Given)")); Root.Children.Add(authors);
        var yt = new StackPanel(); yt.Children.Add(L("Year")); yt.Children.Add(year);
        var tt = new StackPanel(); tt.Children.Add(L("Type")); tt.Children.Add(type);
        var yr = new StackPanel { Orientation = Orientation.Horizontal }; yr.Children.Add(yt); tt.Margin = new Thickness(10, 0, 0, 0); yr.Children.Add(tt);
        Root.Children.Add(yr);
        Root.Children.Add(Field("Title", title));
        Root.Children.Add(Field("Journal / book title", container));
        Root.Children.Add(Row(Field("Volume", volume), Field("Issue", issue), Field("Pages", pages)));
        Root.Children.Add(Row(Field("DOI", doi), Field("Publisher", publisher)));
        Root.Children.Add(L("Ready-made reference (optional). It is added to the list exactly as written; put italic parts between *stars*. If empty, it is built from the fields above."));
        Root.Children.Add(ready);
        var fill = new Button { Content = Loc.T("Fill the fields from this reference"), Padding = new Thickness(10, 2, 10, 2), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0) };
        fill.Click += (_, _) => FillFromReference(true);
        Root.Children.Add(fill);
        Root.Children.Add(L("Authors and year (and, when recognised, title, journal, volume, pages) are filled in; check them."));
        Root.Children.Add(error);
        var ok = new Button { Content = Loc.T("Rename and add to list"), IsDefault = true, Padding = new Thickness(14, 4, 14, 4), Margin = new Thickness(8, 0, 0, 0) };
        var cancel = new Button { Content = Loc.T("Cancel"), IsCancel = true, Padding = new Thickness(14, 4, 14, 4) };
        ok.Click += async (_, _) => await Submit();
        var bar = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        bar.Children.Add(cancel); bar.Children.Add(ok);
        Root.Children.Add(bar);
        Loaded += async (_, _) => { var f = await model.PrefillManual(path); if (authors.Text.Length == 0) authors.Text = f.Authors; if (year.Text.Length == 0) year.Text = f.Year; if (doi.Text.Length == 0) doi.Text = f.Doi; };
    }

    void ShowError(string? m) { error.Text = m ?? ""; error.Visibility = string.IsNullOrEmpty(m) ? Visibility.Collapsed : Visibility.Visible; }

    void FillFromReference(bool overwrite)
    {
        var p = RefParse.Parse(ready.Text);
        if (p == null) { ShowError(Loc.T("Could not read that reference. Fill the fields by hand.")); return; }
        void Put(TextBox b, string v) { if (v.Length > 0 && (overwrite || b.Text.Trim().Length == 0)) b.Text = v; }
        Put(authors, p.Authors); Put(year, p.Year); Put(title, p.Title); Put(container, p.Container);
        Put(volume, p.Volume); Put(issue, p.Issue); Put(pages, p.Pages); Put(doi, p.Doi); Put(publisher, p.Publisher);
        if (p.Type.Length > 0) type.SelectedValue = p.Type;
        ShowError(null);
    }

    async Task Submit()
    {
        if (ready.Text.Trim().Length > 0 && authors.Text.Trim().Length == 0) FillFromReference(false);
        var f = new ManualForm
        {
            Authors = authors.Text, Year = year.Text, Type = type.SelectedValue as string ?? "journal-article", Title = title.Text, Container = container.Text,
            Volume = volume.Text, Issue = issue.Text, Pages = pages.Text, Doi = doi.Text, Publisher = publisher.Text, Ready = ready.Text,
        };
        var err = await model.SubmitManual(path, f);
        if (err != null) ShowError(err); else Close();
    }
}
