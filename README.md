# Biblio

A small macOS app that renames downloaded article PDFs to `Surname - Year.pdf` and keeps an APA (or Harvard, MLA, Chicago, IEEE) reference list as a `.docx` next to them.

- Drag and drop PDFs or folders, or watch folders: new PDFs are renamed automatically.
- Metadata comes from the DOI / title on the first page, looked up in Crossref and OpenAlex (OCR for scanned PDFs). Only the DOI or a few title lines are sent; the PDF itself never leaves your Mac. You can turn online lookup off.
- Files that cannot be resolved get a `!! ` prefix so they sort to the top of the folder; you can enter the details by hand.
- References tab: paste a bibliography, find the articles and download open-access PDFs.
- English and Turkish interface. Requires macOS 13+. Build with the Command Line Tools only (no Xcode): `./build.sh --install`.
- A free OpenAlex API key can be added in Settings for higher limits.

Released under the MIT License. Provided as is, without warranty: always check the generated names and references.

---

# Biblio (eski adı Künye)

PDF makaleleri `Soyad - Yıl.pdf` biçiminde otomatik adlandırır.

- Pencereye PDF/klasör sürükle-bırak, ya da izlenen klasörlere düşenleri otomatik adlandırır.
- Kaynak sırası: DOI → Crossref, başlık → Crossref/OpenAlex, ilk sayfa metni (taranmış PDF'lerde OCR).
- Tek yazar `Soyad - 2020`, iki yazar `A & B - 2020`, üç+ `A et al - 2020`; aynı ad çakışırsa harf eki. Türkçe karakter yok.
- Her işlem geri alınabilir.

Derleme: `./build.sh` (build/Kunye.app), kurulum: `./build.sh --install` (/Applications). Xcode gerekmez, komut satırı araçları yeter.
`cli/` komut satırı sürümü (`--dry-run` destekler); `pdfadi_python_prototip.py` ilk prototip.

## APA künyeleri
Dosya adlandırılırken künyesi APA 7 biçiminde klasördeki `Künyeler.docx` dosyasına eklenir: alfabetik sıralı, asılı girintili, çift aralıklı, dergi/cilt/kitap adları italik. Künyeler gizli `.Künyeler.json` dosyasında tutulur ve docx her eklemede o listeden yeniden üretilir (docx'i elle düzenlediysen değişikliklerin üzerine yazılır; düzenlemeden önce başka yere kopyala). Aynı künye iki kez eklenmez, adlandırma geri alınınca satır silinir. Tam bilgi bulunamazsa satır "[Eksik künye…]" notuyla yazılır.

## Kaynakça sekmesi
Bir kaynakça listesini (.docx veya .txt) bırakınca her satır Crossref'te aranır (başlık, ilk yazar ve yıl satırla uyuşmalı), sonra OpenAlex'ten aynı eserin tüm sürümleri (makale + çalışma kâğıdı/preprint) ve açık erişimli PDF bağlantıları alınır.
Açık erişimli PDF'ler indirme klasörüne indirilir (içerik aynıysa tek kopya tutulur) ve Künye ile adlandırılıp künyeleri eklenir. Makalenin açık PDF'i yoksa (abonelik gerekir) indirme denenmez; DOI sayfası "Sayfayı aç" düğmesiyle (ya da 5'erli gruplar hâlinde) tarayıcıda açılır.

## Dil, adlandırma ve künye stilleri (Ayarlar sekmesi)
- **Dil:** İngilizce (varsayılan) ve Türkçe. Metinler `Sources/Loc.swift` içindeki çeviri tablosunda.
- **Dosya adı biçimi:** hazır kalıplar (Yazar - Yıl, Yazar (Yıl), Yazar - Yıl - Başlık, …) ya da özel kalıp: `{Author} {FirstAuthor} {Year} {Title} {Journal} {DOI}`. Başlık uzunluğu sınırı, kaç yazarın yazılacağı, yazar ayracı (&, and, ve, virgül), "et al" biçimi ve aksanlı harfleri koruma ayarlanabilir; ayarlarda canlı önizleme var. Adı zaten doğru olan dosyalara dokunulmaz.
- **Künye stili:** APA 7, Harvard, MLA 9, Chicago (author-date), IEEE. Klasördeki liste tam yayın bilgisiyle saklandığı için stil değişince yeniden yazılır. Dosya adı da ayarlanabilir (varsayılan References / Künyeler).
- Kod yapısı: `Namer.swift` (adlandırma), `Cite.swift` (stiller), `Loc.swift` (diller), `Engine.swift` (çözümleme), `Model.swift`, `App.swift`, `Docx.swift`, `Biblio.swift` (kaynakça sekmesi).

## Elle giriş
Otomatik çözülemeyen dosyaların satırında **Bilgileri gir…** düğmesi çıkar: yazarlar, yıl, başlık, dergi vb. (ya da hazır künye metni) yazılır; dosya adlandırılır ve künye listeye eklenir. Geri alınabilir.
