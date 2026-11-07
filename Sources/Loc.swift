import Foundation

/// Arayüz dili: İngilizce (varsayılan) ve Türkçe. Anahtar İngilizce metindir; Türkçe karşılığı `pairs` içinde aranır.
/// Eski sürümlerin Türkçe günlük kayıtları İngilizce modda da çevrilebilsin diye karşılıklar iki yönlüdür (+ `legacyTr`).
enum Loc {
    nonisolated(unsafe) static var lang = "en"

    static func t(_ key: String, _ args: CVarArg...) -> String { tv(key, args) }

    static func tv(_ key: String, _ args: [CVarArg]) -> String {
        let k = legacyTr[key] ?? key
        var s = k
        if lang == "tr" { s = enToTr[k] ?? k } else if let en = trToEn[k] { s = en }
        return args.isEmpty ? s : String(format: s, arguments: args)
    }

    static let enToTr: [String: String] = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
    static let trToEn: [String: String] = Dictionary(pairs.map { ($0.1, $0.0) }, uniquingKeysWith: { a, _ in a })

    /// Eski sürümlerin kaydettiği Türkçe notlar -> İngilizce anahtar
    static let legacyTr: [String: String] = [
        "baslik": "title", "calisma-kagidi": "working-paper", "metin": "text", "ocr+metin": "ocr+text", "pdf-alanı": "pdf-author",
        "künye Künyeler.docx'e eklendi": "reference added to the reference list",
        "künye zaten Künyeler.docx'te": "reference was already in the reference list",
    ]

    static let pairs: [(String, String)] = [
        // Kaynak etiketleri (günlükte)
        ("cover", "kapak"), ("filename", "dosya adı"), ("doi", "doi"), ("id", "kimlik"), ("title", "başlık"), ("working-paper", "çalışma kâğıdı"),
        ("isbn", "isbn"), ("text", "metin"), ("ocr+text", "ocr+metin"), ("pdf-author", "pdf yazar alanı"),
        // Kaynakça sürüm etiketleri
        ("article", "makale"), ("article (accepted version)", "makale (kabul edilmiş sürüm)"), ("working paper/preprint", "çalışma kâğıdı/preprint"),
        ("working paper/report", "çalışma kâğıdı/rapor"), ("book chapter", "kitap bölümü"), ("book", "kitap"), ("version", "sürüm"),
        // Günlük notları ve nedenler
        ("reference added to the reference list", "künye listeye eklendi"),
        ("reference was already in the reference list", "künye listede zaten vardı"),
        ("no PDF found in the dropped item", "bırakılan öğede PDF bulunamadı"),
        ("waiting: %@", "beklemede: %@"),
        ("not a PDF", "PDF değil"),
        ("already named (online lookup is needed for the reference)", "zaten adlandırılmış (künye için çevrimiçi arama gerekir)"),
        ("already named", "zaten adlandırılmış"),
        ("text could not be read", "metin okunamadı"),
        ("reference not found (publication data did not match the file name)", "künye bulunamadı (yayın bilgisi dosya adıyla eşleşmedi)"),
        ("could not resolve, rename manually", "çözülemedi, elle adlandırın"),
        ("could not resolve (online lookup is off)", "çözülemedi (çevrimiçi arama kapalı)"),
        ("error: %@", "hata: %@"),
        ("network/limit problem", "ağ/limit sorunu"),
        ("no internet connection (test)", "internet bağlantısı yok (test)"),
        ("OpenAlex limit reached (will retry after %@)", "OpenAlex sınırı doldu (%@ sonrası denenecek)"),
        ("OpenAlex limit reached (HTTP %d; will retry after %@)", "OpenAlex sınırı doldu (HTTP %d; %@ sonrası denenecek)"),
        ("Crossref/doi.org not responding (HTTP %d)", "Crossref/doi.org yanıt vermiyor (HTTP %d)"),
        ("no internet connection or too slow (%d)", "internet bağlantısı yok veya yavaş (%d)"),
        ("[Incomplete reference: title and publication details not found]", "[Eksik künye: başlık ve yayın bilgisi bulunamadı]"),
        // Kaynakça sekmesi
        ("%@: no reference lines found (each line needs a year)", "%@: kaynakça satırı bulunamadı (her satırda yıl olmalı)"),
        ("No matching record found in Crossref", "Crossref'te eşleşen kayıt bulunamadı"),
        ("%@ downloaded", "%@ indirildi"),
        ("no open PDF for the article: open the page and download it with your subscription", "makale için açık PDF yok: sayfayı açıp aboneliğinle indir"),
        ("(OpenAlex unreachable: working-paper versions were not searched)", "(OpenAlex'e ulaşılamadı: çalışma kâğıdı sürümleri aranamadı)"),
        ("no downloadable version or page found", "indirilebilir sürüm ve sayfa bulunamadı"),
        ("Download folder: %@", "İndirme klasörü: %@"),
        ("Change…", "Değiştir…"),
        ("%d article pages are waiting to be opened (to download with your subscription)", "%d makale sayfası açılmayı bekliyor (abonelikle indirilecekler)"),
        ("Open next 5 pages", "Sonraki 5 sayfayı aç"),
        ("Drop a reference list (.docx or .txt)", "Kaynakça listesini (.docx veya .txt) bırak"),
        ("Open-access PDFs (article and working-paper versions) are downloaded; for articles that need a subscription the page is opened.",
         "Açık erişimli PDF'ler (makale ve çalışma kâğıdı sürümü) indirilir; abonelik gerekenlerin sayfası açılır."),
        ("Reopen", "Yeniden aç"),
        ("Open page", "Sayfayı aç"),
        // Sekmeler ve Adlandır sekmesi
        ("Rename", "Adlandır"), ("References", "Kaynakça"), ("Settings", "Ayarlar"),
        ("Drop PDFs or folders", "PDF veya klasör bırakın"),
        ("Files are renamed like: %@", "Dosyalar şöyle adlandırılır: %@"),
        ("%d files processing…", "%d dosya işleniyor…"),
        ("%d files are being skipped because they could not be resolved earlier.", "%d dosya daha önce çözülemediği için atlanıyor."),
        ("Retry", "Yeniden dene"),
        ("%d files waiting", "%d dosya beklemede"),
        ("%@. Will retry automatically.", "%@. Otomatik olarak yeniden denenecek."),
        ("Retry now", "Şimdi dene"),
        ("Watched folders", "İzlenen klasörler"),
        ("No folders yet. PDFs that land in a folder you add are renamed automatically.", "Henüz klasör yok. Eklediğiniz klasöre düşen PDF'ler otomatik adlandırılır."),
        ("Add folder…", "Klasör ekle…"),
        ("Rename watched folders automatically", "İzlenen klasörleri otomatik adlandır"),
        ("Recent activity", "Son işlemler"),
        ("Undo last", "Son işlemi geri al"),
        ("Undo", "Geri al"),
        ("source: %@", "kaynak: %@"),
        ("source: %@ (guess, please check)", "kaynak: %@ (tahmin, kontrol edin)"),
        // Elle giriş
        ("manual", "elle girildi"), ("file not found", "dosya bulunamadı"),
        ("Enter details…", "Bilgileri gir…"),
        ("Enter details manually", "Bilgileri elle gir"),
        ("Authors (one per line: Family, Given)", "Yazarlar (her satıra bir yazar: Soyad, Ad)"),
        ("Year", "Yıl"), ("Type", "Tür"),
        ("Journal article", "Dergi makalesi"), ("Book", "Kitap"), ("Book chapter", "Kitap bölümü"), ("Report / working paper", "Rapor / çalışma kâğıdı"),
        ("Title", "Başlık"), ("Journal / book title", "Dergi / kitap adı"), ("Volume", "Cilt"), ("Issue", "Sayı"), ("Pages", "Sayfalar"),
        ("DOI", "DOI"), ("Publisher", "Yayıncı"),
        ("Ready-made reference (optional). It is added to the list exactly as written; put italic parts between *stars*. If empty, it is built from the fields above.",
         "Hazır künye (isteğe bağlı). Listeye yazdığınız gibi eklenir; italik kısımları *yıldız* içine alın. Boşsa yukarıdaki alanlardan oluşturulur."),
        ("Rename and add to list", "Adlandır ve listeye ekle"),
        ("%@. File renamed to “%@” so it appears at the top of the folder.", "%@. Dosya adı “%@” olarak değiştirildi; klasörün en üstünde görünür."),
        ("Fill the fields from this reference", "Alanları bu künyeden doldur"),
        ("Authors and year (and, when recognised, title, journal, volume, pages) are filled in; check them.", "Yazarlar ve yıl (tanınırsa başlık, dergi, cilt, sayfa da) doldurulur; kontrol edin."),
        ("Could not read that reference. Fill the fields by hand.", "Künye okunamadı. Alanları elle doldurun."),
        ("Cancel", "Vazgeç"),
        ("Enter at least one author", "En az bir yazar girin"),
        ("The year must be four digits (or leave it empty)", "Yıl dört haneli olmalı (ya da boş bırakın)"),
        // Geçmiş temizleme
        ("Clear history", "Geçmişi temizle"),
        ("Remove this row from the list. Files and the reference list are not changed.", "Bu satırı listeden kaldır. Dosyalar ve künye listesi değişmez."),
        ("History", "Geçmiş"),
        ("Clears only what is shown in the lists. Files and reference lists stay as they are, but cleared activity can no longer be undone.",
         "Yalnızca listelerde görünenleri temizler. Dosyalar ve künye listeleri olduğu gibi kalır; temizlenen işlemler artık geri alınamaz."),
        // Ayarlar sekmesi
        ("General", "Genel"),
        ("Language", "Dil"),
        ("Also process the PDFs already inside a folder when it is added", "Klasör eklenince içindeki mevcut PDF'leri de işle"),
        ("Start at login", "Oturum açılışında başlat"),
        ("File naming", "Dosya adlandırma"),
        ("Pattern", "Biçim"),
        ("Custom…", "Özel…"),
        ("Click a field to add it, or type your own pattern (spaces, dashes, brackets are fine). A pattern needs at least {Author} or {Title}.",
         "Alan eklemek için tıklayın ya da kendi biçiminizi yazın (boşluk, tire, parantez kullanabilirsiniz). Biçimde en az {Author} veya {Title} olmalı."),
        ("Title length limit: %d characters", "Başlık uzunluk sınırı: %d karakter"),
        ("List up to %d authors, then use “et al”", "En fazla %d yazar adı yaz, fazlasında “et al” kullan"),
        ("Between authors", "Yazarlar arası"),
        ("More authors", "Çok yazarlıysa"),
        ("Keep accented letters (otherwise Turkish letters become plain ASCII)", "Aksanlı harfleri koru (kapalıysa Türkçe harfler sade ASCII olur)"),
        ("Preview: %@", "Önizleme: %@"),
        ("Files that are already named stay as they are. Duplicate names get a letter after the year (2013b).",
         "Adı zaten doğru olan dosyalar olduğu gibi kalır. Aynı ad çıkarsa yılın sonuna harf eklenir (2013b)."),
        ("Reference list", "Künye listesi"),
        ("Write a reference list (.docx) in each folder, sorted alphabetically", "Her klasöre alfabetik sıralı künye listesi (.docx) yaz"),
        ("Citation style", "Künye stili"),
        ("File name:", "Dosya adı:"),
        ("Titles in italics in the .docx. Style rules are approximations: please check against your style guide.",
         ".docx içinde italik kısımlar italik yazılır. Stil kuralları yaklaşıktır: kendi stil kılavuzunuzla kontrol edin."),
        ("Lookup", "Arama"),
        ("Search online (Crossref, OpenAlex): most accurate", "Çevrimiçi ara (Crossref, OpenAlex): en doğru sonuç"),
        ("OpenAlex key:", "OpenAlex anahtarı:"),
        ("free key: openalex.org → Settings → API key", "ücretsiz anahtar: openalex.org → Settings → API key"),
        ("Guess unresolved files from the page text (less reliable; year becomes xxxx if missing)",
         "Bulunamayanları sayfa metninden tahmin et (daha az güvenilir; yıl yoksa xxxx)"),
        ("When online search is on, only the DOI and the title lines of the first page are sent; the file itself never leaves your Mac.",
         "Çevrimiçi arama açıkken yalnızca DOI ve ilk sayfadaki başlık satırları sorgulanır; dosyanın kendisi Mac'inizden çıkmaz."),
    ]
}
