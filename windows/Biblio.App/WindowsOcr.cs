using Biblio.Core;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace Biblio.App;

/// <summary>Taranmış PDF sayfaları için Windows'un yerleşik OCR'ı (cihaz üzerinde çalışır). Dil: yüklü dil paketlerinden Türkçe/İngilizce.</summary>
public class WindowsOcr : IOcr
{
    readonly List<OcrEngine> engines = new();

    public WindowsOcr()
    {
        foreach (var tag in new[] { "tr", "en-US" })
        {
            try { var e = OcrEngine.TryCreateFromLanguage(new Language(tag)); if (e != null) engines.Add(e); } catch { }
        }
        if (engines.Count == 0) { var e = OcrEngine.TryCreateFromUserProfileLanguages(); if (e != null) engines.Add(e); }
    }

    public string OcrPage(string pdfPath, int pageIndex)
    {
        if (engines.Count == 0) return "";
        using var fs = File.OpenRead(pdfPath);
        using var bmp = PDFtoImage.Conversion.ToImage(fs, pageIndex, leaveOpen: true, options: new PDFtoImage.RenderOptions(Dpi: 200));
        using var data = bmp.Encode(SkiaSharp.SKEncodedImageFormat.Png, 100);
        using var ms = new MemoryStream(data.ToArray());
        using var ras = ms.AsRandomAccessStream();
        var decoder = BitmapDecoder.CreateAsync(ras).AsTask().GetAwaiter().GetResult();
        using var sb = decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied).AsTask().GetAwaiter().GetResult();
        string best = "";
        foreach (var e in engines)
        {
            var res = e.RecognizeAsync(sb).AsTask().GetAwaiter().GetResult();
            var text = string.Join("\n", res.Lines.Select(l => l.Text));
            if (text.Length > best.Length) best = text;
        }
        return best;
    }
}
