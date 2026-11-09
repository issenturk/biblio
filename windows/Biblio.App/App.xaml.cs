using System.IO;
using System.Windows;

namespace Biblio.App;

public partial class App : Application
{
    /// <summary>Beklenmeyen hatalar sessizce kaybolmasın: pencerede gösterilir ve %APPDATA%\Biblio\error.log dosyasına yazılır.</summary>
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, ev) => { Report(ev.Exception); ev.Handled = true; };
        TaskScheduler.UnobservedTaskException += (_, ev) => { Report(ev.Exception); ev.SetObserved(); };
    }

    static void Report(Exception ex)
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Biblio");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "error.log"), DateTime.Now + "\n" + ex + "\n\n");
        }
        catch { }
        try { Current?.Dispatcher.BeginInvoke(() => MessageBox.Show(ex.GetBaseException().Message + "\n\n(%APPDATA%\\Biblio\\error.log)", "Biblio")); } catch { }
    }
}
