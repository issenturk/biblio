namespace Biblio.App;

/// <summary>İngilizce anahtar -> Türkçe çeviri. Varsayılan dil İngilizce.</summary>
public static class Loc
{
    public static string Lang = "en";

    static readonly Dictionary<string, string> Tr = new()
    {
        ["Rename"] = "Adlandır", ["Settings"] = "Ayarlar", ["References"] = "Kaynakça",
        ["Drop PDFs or folders here"] = "PDF veya klasörleri buraya bırakın",
        ["Files are renamed like: {0}"] = "Dosyalar şöyle adlandırılır: {0}",
        ["Watched folders"] = "İzlenen klasörler", ["Add folder…"] = "Klasör ekle…", ["Remove"] = "Kaldır",
        ["Watching"] = "İzleme açık", ["Recent activity"] = "Son işlemler", ["Undo"] = "Geri al", ["Undo last"] = "Sonuncuyu geri al",
        ["Clear history"] = "Geçmişi temizle", ["Remove this row from the list (files and the reference list are not touched)"] = "Bu satırı listeden kaldır (dosyalara ve künye listesine dokunulmaz)",
        ["Enter details…"] = "Bilgileri gir…", ["Working…"] = "Çalışılıyor…", ["Idle"] = "Hazır",
        ["source: {0}"] = "kaynak: {0}", ["source: {0} (guess, please check)"] = "kaynak: {0} (tahmin, lütfen kontrol edin)",
        ["waiting: {0}"] = "beklemede: {0}", ["{0}. Will retry automatically."] = "{0}. Otomatik tekrar denenecek.",
        ["Retry now"] = "Şimdi tekrar dene",
        ["could not resolve, rename manually"] = "çözülemedi, elle adlandırın",
        ["could not resolve (online lookup is off)"] = "çözülemedi (çevrimiçi arama kapalı)",
        ["text could not be read"] = "metin okunamadı", ["not a PDF"] = "PDF değil", ["file not found"] = "dosya bulunamadı",
        ["already named"] = "zaten adlandırılmış",
        ["already named (online lookup is needed for the reference)"] = "zaten adlandırılmış (künye için çevrimiçi arama gerekir)",
        ["reference not found (publication data did not match the file name)"] = "künye bulunamadı (yayın bilgisi dosya adıyla uyuşmadı)",
        ["reference added to the reference list"] = "künye listeye eklendi", ["reference was already in the reference list"] = "künye zaten listede",
        ["{0}. File renamed to “{1}” so it appears at the top of the folder."] = "{0}. Dosya adı “{1}” olarak değiştirildi; klasörün en üstünde görünür.",
        ["cover"] = "kapak sayfası", ["filename"] = "dosya adı", ["id"] = "kimlik (SSRN/arXiv/NBER)", ["doi"] = "DOI", ["isbn"] = "ISBN",
        ["title"] = "başlık araması", ["working-paper"] = "çalışma kâğıdı kaydı", ["manual"] = "elle girildi",
        ["text"] = "sayfa metni", ["ocr+text"] = "OCR + metin", ["pdf-author"] = "PDF yazar alanı",
        ["General"] = "Genel", ["Language"] = "Dil", ["Start at login"] = "Oturum açılışında başlat",
        ["Also process the PDFs already inside a folder when it is added"] = "Klasör eklenince içindeki PDF'leri de işle",
        ["File naming"] = "Dosya adı", ["Preset"] = "Hazır kalıp", ["Template"] = "Kalıp", ["Title length limit"] = "Başlık uzunluğu sınırı",
        ["Authors written before “et al”"] = "“et al”dan önce yazılan yazar sayısı", ["Author separator"] = "Yazar ayracı",
        ["Keep accented letters (Turkish characters etc.)"] = "Aksanlı harfleri koru (Türkçe karakterler vb.)",
        ["Preview: {0}"] = "Önizleme: {0}",
        ["Reference list"] = "Künye listesi", ["Write a reference list (.docx) next to the PDFs"] = "PDF'lerin yanına künye listesi (.docx) yaz",
        ["Citation style"] = "Künye stili", ["File name of the list"] = "Liste dosya adı",
        ["Lookup"] = "Arama", ["Look up the publication online (Crossref, OpenAlex). Only the DOI or a few title lines are sent; the PDF is never uploaded."] =
            "Yayını çevrimiçi ara (Crossref, OpenAlex). Yalnızca DOI veya birkaç başlık satırı gönderilir; PDF'in kendisi yüklenmez.",
        ["OpenAlex API key (optional, free)"] = "OpenAlex API anahtarı (isteğe bağlı, ücretsiz)",
        ["Guess from the page text when nothing is found (less reliable)"] = "Hiçbir şey bulunamazsa sayfa metninden tahmin et (daha az güvenilir)",
        ["History"] = "Geçmiş", ["Clearing history only empties the lists you see; files and reference lists are not touched, but cleared activity can no longer be undone."] =
            "Geçmişi temizlemek yalnızca görünen listeleri boşaltır; dosyalara ve künye listelerine dokunmaz, ancak temizlenen işlemler artık geri alınamaz.",
        ["Enter details manually"] = "Bilgileri elle gir", ["Authors (one per line: Family, Given)"] = "Yazarlar (her satıra bir kişi: Soyad, Ad)",
        ["Year"] = "Yıl", ["Type"] = "Tür", ["Journal article"] = "Dergi makalesi", ["Book"] = "Kitap", ["Book chapter"] = "Kitap bölümü",
        ["Report / working paper"] = "Rapor / çalışma kâğıdı", ["Title"] = "Başlık", ["Journal / book title"] = "Dergi / kitap adı",
        ["Volume"] = "Cilt", ["Issue"] = "Sayı", ["Pages"] = "Sayfalar", ["DOI"] = "DOI", ["Publisher"] = "Yayıncı",
        ["Ready-made reference (optional). It is added to the list exactly as written; put italic parts between *stars*. If empty, it is built from the fields above."] =
            "Hazır künye (isteğe bağlı). Listeye yazdığınız gibi eklenir; italik kısımları *yıldız* içine alın. Boşsa yukarıdaki alanlardan oluşturulur.",
        ["Fill the fields from this reference"] = "Alanları bu künyeden doldur",
        ["Authors and year (and, when recognised, title, journal, volume, pages) are filled in; check them."] =
            "Yazarlar ve yıl (tanınırsa başlık, dergi, cilt, sayfa da) doldurulur; kontrol edin.",
        ["Could not read that reference. Fill the fields by hand."] = "Künye okunamadı. Alanları elle doldurun.",
        ["Rename and add to list"] = "Adlandır ve listeye ekle", ["Cancel"] = "Vazgeç",
        ["Enter at least one author"] = "En az bir yazar girin", ["The year must be four digits (or leave it empty)"] = "Yıl dört haneli olmalı (ya da boş bırakın)",
        ["Open the reference list"] = "Künye listesini aç", ["Open folder"] = "Klasörü aç",
        ["{0}: no reference lines found (each line needs a year)"] = "{0}: kaynakça satırı bulunamadı (her satırda yıl olmalı)",
        ["No matching record found in Crossref"] = "Crossref'te eşleşen kayıt bulunamadı",
        ["{0} downloaded"] = "{0} indirildi",
        ["no open PDF for the article: open the page and download it with your subscription"] = "makale için açık PDF yok: sayfayı açıp aboneliğinle indir",
        ["(OpenAlex unreachable: working-paper versions were not searched)"] = "(OpenAlex'e ulaşılamadı: çalışma kâğıdı sürümleri aranamadı)",
        ["no downloadable version or page found"] = "indirilebilir sürüm ve sayfa bulunamadı",
        ["network/limit problem"] = "ağ/sınır sorunu",
        ["Download folder: {0}"] = "İndirme klasörü: {0}", ["Change…"] = "Değiştir…",
        ["{0} article pages are waiting to be opened (to download with your subscription)"] = "{0} makale sayfası açılmayı bekliyor (abonelikle indirilecekler)",
        ["Open next 5 pages"] = "Sonraki 5 sayfayı aç",
        ["Drop a reference list (.docx or .txt)"] = "Kaynakça listesini (.docx veya .txt) bırakın",
        ["Open-access PDFs (article and working-paper versions) are downloaded; for articles that need a subscription the page is opened."] =
            "Açık erişimli PDF'ler (makale ve çalışma kâğıdı sürümü) indirilir; abonelik gerekenlerin sayfası açılır.",
        ["Reopen"] = "Yeniden aç", ["Open page"] = "Sayfayı aç",
        ["article"] = "makale", ["article (accepted version)"] = "makale (kabul edilen sürüm)", ["working paper/preprint"] = "çalışma kâğıdı/ön baskı",
        ["working paper/report"] = "çalışma kâğıdı/rapor", ["book chapter"] = "kitap bölümü", ["book"] = "kitap", ["version"] = "sürüm",
        ["Start a new reference list for this folder (the current .docx is deleted)"] = "Bu klasör için yeni künye listesi başlat (mevcut .docx silinir)",
        ["Start a new reference list for this folder?"] = "Bu klasör için yeni künye listesi başlatılsın mı?",
        ["There is no Biblio reference list in this folder."] = "Bu klasörde Biblio'nun yazdığı bir künye listesi yok.",
        ["The current reference list (.docx) of this folder will be deleted and the next references start a fresh list. PDFs are not touched. Continue?"] =
            "Bu klasörün mevcut künye listesi (.docx) silinecek, sonraki künyeler boş bir listeye yazılacak. PDF'lere dokunulmaz. Devam edilsin mi?",
        ["Biblio renames article PDFs to Surname - Year and keeps a reference list."] = "Biblio, makale PDF'lerini Soyad - Yıl biçiminde adlandırır ve künye listesi tutar.",
    };

    public static string T(string key, params object[] args)
    {
        var s = Lang == "tr" && Tr.TryGetValue(key, out var v) ? v : key;
        return args.Length == 0 ? s : string.Format(s, args);
    }
}
