import Foundation

/// Dosya adlandırma tercihleri (ayarlardan gelir)
struct NamingPrefs: Equatable {
    var template = "{Author} - {Year}"
    var titleMax = 60          // {Title} ve {Journal} için en fazla karakter
    var maxAuthors = 2         // bu sayıya kadar yazar adı yazılır; fazlası "ilk yazar + et al"
    var andWord = "&"          // yazarlar arası bağlaç: "&", "and", "ve" ya da ","
    var etAl = "et al"
    var keepAccents = false    // false: Türkçe/aksanlı harfler ASCII'ye çevrilir
}

/// Bir eserden adlandırmada kullanılabilen alanlar
struct NameFields {
    var authors: [String]      // soyadları
    var year: Int?
    var title = ""
    var journal = ""
    var doi = ""
}

enum Namer {
    /// (kimlik, şablon, İngilizce ad, Türkçe ad)
    static let presets: [(id: String, template: String, en: String, tr: String)] = [
        ("author-year", "{Author} - {Year}", "Author - Year", "Yazar - Yıl"),
        ("author-year-paren", "{Author} ({Year})", "Author (Year)", "Yazar (Yıl)"),
        ("author-year-title", "{Author} - {Year} - {Title}", "Author - Year - Title", "Yazar - Yıl - Başlık"),
        ("year-author-title", "{Year} - {Author} - {Title}", "Year - Author - Title", "Yıl - Yazar - Başlık"),
        ("author-year-journal", "{Author} - {Year} - {Journal}", "Author - Year - Journal", "Yazar - Yıl - Dergi"),
        ("author-title", "{Author} - {Title}", "Author - Title", "Yazar - Başlık"),
        ("underscore", "{FirstAuthor}_{Year}", "FirstAuthor_Year", "İlkYazar_Yıl"),
    ]

    static let defaultTemplate = "{Author} - {Year}"
    static let tokens = ["{Author}", "{FirstAuthor}", "{Year}", "{Title}", "{Journal}", "{DOI}"]

    static func templateIsUsable(_ t: String) -> Bool {
        let low = t.lowercased()
        return low.contains("{author}") || low.contains("{firstauthor}") || low.contains("{title}")
    }

    // MARK: Temizlik

    private static let separators = CharacterSet(charactersIn: " -_–—,.:;")

    static func capitalizeIfShouting(_ s: String) -> String {
        (s == s.uppercased() && s != s.lowercased()) ? s.lowercased().capitalized : s
    }

    /// Dosya adında sorun çıkaran karakterleri temizler; aksan korunmuyorsa ASCII'ye indirger.
    static func clean(_ s: String, keepAccents: Bool) -> String {
        var t = Apa.clean(s)
        if keepAccents {
            t = t.replacingOccurrences(of: ":", with: " -")
            t = String(t.unicodeScalars.filter { !"/\\*?\"<>|".unicodeScalars.contains($0) && !CharacterSet.controlCharacters.contains($0) })
            return t.split(separator: " ").joined(separator: " ")
        }
        return Engine.fold(t)
    }

    /// En fazla `max` karakter; sözcük ortasından kesilmez.
    static func truncate(_ s: String, _ max: Int) -> String {
        guard s.count > max, max > 0 else { return s }
        var cut = String(s.prefix(max))
        if let sp = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: sp) >= max / 2 { cut = String(cut[..<sp]) }
        return cut.trimmingCharacters(in: separators)
    }

    static func authorString(_ authors: [String], prefs: NamingPrefs) -> String {
        let fam = authors.map { capitalizeIfShouting(clean($0, keepAccents: prefs.keepAccents)) }.filter { !$0.isEmpty }
        guard !fam.isEmpty else { return "" }
        let limit = max(1, prefs.maxAuthors)
        if fam.count > limit { return "\(fam[0]) \(prefs.etAl)" }
        if fam.count == 1 { return fam[0] }
        if prefs.andWord == "," { return fam.joined(separator: ", ") }
        if fam.count == 2 { return "\(fam[0]) \(prefs.andWord) \(fam[1])" }
        return fam.dropLast().joined(separator: ", ") + " \(prefs.andWord) " + fam.last!
    }

    // MARK: Üretim

    /// `suffix`: aynı ada sahip dosyalar için yıl harfi ("b", "c"); {Year} yoksa adın sonuna eklenir.
    static func render(_ f: NameFields, prefs: NamingPrefs, suffix: String = "") -> String {
        var template = prefs.template.trimmingCharacters(in: .whitespaces)
        if !templateIsUsable(template) { template = defaultTemplate }
        let hasYear = template.lowercased().contains("{year}")

        func value(_ token: String) -> String {
            switch token.lowercased() {
            case "author": return authorString(f.authors, prefs: prefs)
            case "firstauthor": return authorString(Array(f.authors.prefix(1)), prefs: prefs)
            case "year": return (f.year.map(String.init) ?? "xxxx") + suffix
            case "title": return truncate(clean(f.title, keepAccents: prefs.keepAccents), prefs.titleMax)
            case "journal": return truncate(clean(f.journal, keepAccents: prefs.keepAccents), prefs.titleMax)
            case "doi": return clean(f.doi.replacingOccurrences(of: "/", with: "_"), keepAccents: true).replacingOccurrences(of: " ", with: "")
            default: return ""
            }
        }

        var out = ""
        let ns = template as NSString
        var last = 0
        if let re = try? NSRegularExpression(pattern: #"\{(\w+)\}"#) {
            for m in re.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += value(ns.substring(with: m.range(at: 1)))
                last = m.range.location + m.range.length
            }
        }
        out += ns.substring(from: last)
        if !hasYear { out += suffix }

        // boş kalan alanların bıraktığı süsleri temizle: "()", "[]", art arda ayraçlar
        out = out.replacingOccurrences(of: #"\(\s*\)|\[\s*\]"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(\s*[-_–—,]\s*){2,}"#, with: " - ", options: .regularExpression)
        out = out.trimmingCharacters(in: separators)
        while out.hasPrefix(".") { out.removeFirst() }
        if out.count > 200 { out = String(out.prefix(200)).trimmingCharacters(in: separators) }
        return out.isEmpty ? "Untitled" : out
    }
}
