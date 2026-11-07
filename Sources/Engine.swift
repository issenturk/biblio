import Foundation
import PDFKit
import Vision
import AppKit
import NaturalLanguage

// Biblio önce PDF'in kendi içeriğine bakar. "Çevrimiçi ara" açıksa DOI ve ilk sayfadaki başlık satırları
// Crossref / OpenAlex / Open Library'ye sorulur (dosyanın kendisi gönderilmez).

enum EngineError: Error { case network }

struct Person: Codable { var family: String; var given: String }

/// APA künyesi için tam yayın bilgisi (kaynak: Crossref, doi.org, OpenAlex, Open Library)
struct Ref: Codable {
    var authors: [Person] = []
    var editors: [Person] = []
    var year: Int?
    var title = ""
    var container = ""     // dergi veya kitap adı
    var volume = ""
    var issue = ""
    var pages = ""
    var doi = ""
    var publisher = ""
    var type = ""
}

struct Found {
    var authors: [String]
    var year: Int?   // bulunamazsa dosya adında "xxxx" yazılır
    var how: String
    var ref: Ref?
}

struct PageData {
    var pages: [String]
    var metaAuthor: String?
    var ocr: Bool
    var filename = ""
    var text: String { pages.joined(separator: "\n") }
}

enum Engine {
    static let currentYear = Calendar.current.component(.year, from: Date())

    // MARK: Metin yardimcilari

    /// ASCII'ye indirger. Satir sonlari bosluga, ligatürler (ﬀ, ﬁ…) harflere çevrilir.
    static func fold(_ s: String) -> String {
        var t = s.precomposedStringWithCompatibilityMapping
        t = String(t.unicodeScalars.map { CharacterSet.whitespacesAndNewlines.contains($0) ? Character(" ") : Character($0) })
        for (a, b) in [("’", "'"), ("‘", "'"), ("ı", "i"), ("İ", "I"), ("ß", "ss"), ("ø", "o"), ("Ø", "O"), ("ł", "l"), ("Ł", "L"), ("đ", "d"), ("æ", "ae"), ("œ", "oe")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        t = t.folding(options: [.diacriticInsensitive], locale: nil)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -'")
        t = String(t.filter { allowed.contains($0) })
        return t.split(separator: " ").joined(separator: " ")
    }

    static func squash(_ s: String) -> String {
        fold(s).lowercased().split { !$0.isLetter && !$0.isNumber }.joined()
    }

    static func matches(_ pattern: String, in s: String, group: Int = 0) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            let r = $0.range(at: group)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    static func groups(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : (s as NSString).substring(with: m.range(at: $0)) }
    }

    // MARK: PDF okuma (+ taranmis PDF icin OCR; Vision tamamen cihaz uzerinde calisir)

    static func read(_ url: URL) -> PageData {
        guard let doc = PDFDocument(url: url) else { return PageData(pages: [], metaAuthor: nil, ocr: false, filename: Flag.strip(url.lastPathComponent)) }
        if doc.isLocked { _ = doc.unlock(withPassword: "") }
        var pages: [String] = []
        for i in 0..<min(2, doc.pageCount) { pages.append(doc.page(at: i)?.string ?? "") }
        let author = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        var ocr = false
        if pages.joined().trimmingCharacters(in: .whitespacesAndNewlines).count < 80 {
            pages = (0..<min(2, doc.pageCount)).map { ocrPage(doc.page(at: $0)) }
            ocr = true
        }
        return PageData(pages: pages, metaAuthor: author, ocr: ocr, filename: Flag.strip(url.lastPathComponent))
    }

    static func ocrPage(_ page: PDFPage?) -> String {
        guard let page else { return "" }
        let box = page.bounds(for: .mediaBox)
        let img = page.thumbnail(of: CGSize(width: box.width * 2, height: box.height * 2), for: .mediaBox)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        func run(langs: [String]?) -> String? {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            if let langs { req.recognitionLanguages = langs }
            do { try VNImageRequestHandler(cgImage: cg).perform([req]) } catch { return nil }
            return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }
        return run(langs: ["tr-TR", "en-US"]) ?? run(langs: nil) ?? ""
    }

    // MARK: Ayarlar

    static var openAlexKey: String?
    static var onlineEnabled = true
    static var useFilename = true        // ölçüm modunda kapatılır (zaten adlandırılmış dosyalar kendini doğrular)
    static var guessEnabled = false      // kesin olmayan, sayfa metninden tahmin
    static var openAlexCooldownUntil = Date.distantPast
    static var naming = NamingPrefs()     // dosya adı tercihleri (ayarlardan)
    static var citeStyle = CiteStyle.apa  // künye stili (ayarlardan)
    static var lastIssue = ""           // son ağ/limit sorununun açıklaması (arayüzde gösterilir)

    // MARK: Metin karsilastirma

    static func norm(_ s: String) -> String {
        fold(s).lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    static func tokens(_ s: String) -> Set<String> {
        Set(norm(s).split(separator: " ").map(String.init).filter { $0.count > 3 })
    }

    static func titleInText(_ title: String, _ text: String) -> Bool {
        let tt = tokens(title)
        if tt.isEmpty { return false }
        return Double(tt.intersection(tokens(text)).count) / Double(tt.count) >= 0.6
    }

    /// Baslik sayfada kesintisiz bir ifade olarak geciyor mu? Kelime araliklari kaybolmus PDF'ler icin bosluksuz karsilastirma da yapilir.
    static func containsPhrase(_ text: String, _ title: String) -> Bool {
        let t = norm(title)
        guard t.count >= 8 else { return false }
        if norm(text).contains(t) { return true }
        let st = t.replacingOccurrences(of: " ", with: "")
        return st.count >= 12 && squash(text).contains(st)
    }

    /// Yazar soyadi sayfada geciyor mu? Onsoz/editor satirlari sayilmaz.
    static func authorOnPage(_ authors: [String], _ text: String) -> Bool {
        let skip = ["foreword", "preface", "editor", "edited by", "supervisor", "advisor", "danışman", "translated", "önsöz"]
        let kept = text.split(separator: "\n").filter { l in !skip.contains { l.lowercased().contains($0) } }.joined(separator: "\n")
        let st = squash(kept)
        return authors.contains { let f = squash($0); return f.count >= 3 && st.contains(f) }
    }

    // MARK: Ag

    /// Sorgu değeri için kodlama: "&", "+", "=", "#" da kodlanmalı (urlQueryAllowed bunları olduğu gibi bırakır ve sorguyu keser).
    static func encodeQuery(_ s: String) -> String {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=#;/?")
        return s.addingPercentEncoding(withAllowedCharacters: set) ?? s
    }

    static func hhmm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }

    static func getJSON(_ urlString: String, accept: String? = nil) async throws -> [String: Any]? {
        var urlString = urlString
        let isOA = urlString.contains("api.openalex.org")
        if isOA, let k = openAlexKey, !k.isEmpty { urlString += "&api_key=" + k }
        if ProcessInfo.processInfo.environment["BIBLIO_OFFLINE"] != nil { lastIssue = Loc.t("no internet connection (test)"); throw EngineError.network }
        if isOA && Date() < openAlexCooldownUntil { lastIssue = Loc.t("OpenAlex limit reached (will retry after %@)", hhmm(openAlexCooldownUntil)); throw EngineError.network }   // limit doluysa gereksiz bekleme
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Biblio/1.0", forHTTPHeaderField: "User-Agent")
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        for attempt in 0..<3 {
            do {
                let (d, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
                if code == 429 || code >= 500 {
                    if isOA {
                        openAlexCooldownUntil = Date().addingTimeInterval(openAlexKey?.isEmpty == false ? 300 : 900)
                        lastIssue = Loc.t("OpenAlex limit reached (HTTP %d; will retry after %@)", code, hhmm(openAlexCooldownUntil))
                        throw EngineError.network
                    }
                    if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(1_500_000_000 * (attempt + 1))); continue }
                    lastIssue = Loc.t("Crossref/doi.org not responding (HTTP %d)", code)
                    throw EngineError.network
                }
                if code != 200 { return nil }
                try? await Task.sleep(nanoseconds: 60_000_000)
                return try JSONSerialization.jsonObject(with: d) as? [String: Any]
            } catch let e as URLError {
                switch e.code {
                case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                    lastIssue = Loc.t("no internet connection or too slow (%d)", e.code.rawValue)
                    throw EngineError.network
                default: return nil
                }
            } catch let e as EngineError { throw e } catch { return nil }
        }
        return nil
    }

    struct Work { var authors: [String]; var year: Int?; var title: String; var type: String; var ref: Ref? = nil }

    static func persons(_ arr: [[String: Any]]) -> [Person] {
        arr.compactMap { a in
            if let f = a["family"] as? String { return Person(family: f, given: a["given"] as? String ?? "") }
            if let n = (a["name"] as? String) ?? (a["literal"] as? String) { return Person(family: n, given: "") }
            return nil
        }
    }

    static func crossrefWork(_ m: [String: Any]) -> Work {
        let ps = persons(m["author"] as? [[String: Any]] ?? [])
        var year: Int?
        for k in ["published-print", "published-online", "issued", "published"] {
            if let o = m[k] as? [String: Any], let dp = o["date-parts"] as? [[Any]], let y = dp.first?.first as? Int { year = y; break }
        }
        let title = (m["title"] as? [String])?.first ?? ""
        let type = m["type"] as? String ?? ""
        let ref = Ref(authors: ps, editors: persons(m["editor"] as? [[String: Any]] ?? []), year: year, title: title,
                      container: (m["container-title"] as? [String])?.first ?? "", volume: m["volume"] as? String ?? "",
                      issue: m["issue"] as? String ?? "", pages: m["page"] as? String ?? "", doi: m["DOI"] as? String ?? "",
                      publisher: m["publisher"] as? String ?? "", type: type)
        return Work(authors: ps.map { $0.family }, year: year, title: title, type: type, ref: ref)
    }

    /// doi.org içerik pazarlığı (CSL JSON): Crossref dışındaki kayıt kurumlarını da (DataCite vb.) kapsar.
    static func cslWork(_ m: [String: Any]) -> Work {
        let ps = persons(m["author"] as? [[String: Any]] ?? [])
        var year: Int?
        if let o = m["issued"] as? [String: Any], let dp = o["date-parts"] as? [[Any]], let y = dp.first?.first as? Int { year = y }
        let title = m["title"] as? String ?? ""
        let type = m["type"] as? String ?? ""
        let ref = Ref(authors: ps, editors: persons(m["editor"] as? [[String: Any]] ?? []), year: year, title: title,
                      container: m["container-title"] as? String ?? "", volume: "\(m["volume"] ?? "")".replacingOccurrences(of: "Optional(", with: "").replacingOccurrences(of: ")", with: "").replacingOccurrences(of: "<nil>", with: ""),
                      issue: m["issue"] as? String ?? "", pages: m["page"] as? String ?? "", doi: m["DOI"] as? String ?? "",
                      publisher: m["publisher"] as? String ?? "", type: type)
        return Work(authors: ps.map { $0.family }, year: year, title: title, type: type, ref: ref)
    }

    /// "Matthew E. Kahn" -> (Kahn, Matthew E.); "Jan van der Heijden" -> (van der Heijden, Jan)
    static func splitName(_ full: String) -> Person {
        let toks = full.split(separator: " ").map(String.init)
        guard toks.count > 1 else { return Person(family: full, given: "") }
        var i = toks.count - 1
        while i > 1, ["van", "von", "de", "der", "den", "da", "di", "la", "le", "ter", "bin", "al", "el", "du", "dos", "del"].contains(toks[i - 1].lowercased()) { i -= 1 }
        return Person(family: toks[i...].joined(separator: " "), given: toks[..<i].joined(separator: " "))
    }

    static func openAlexWork(_ m: [String: Any]) -> Work {
        let names = (m["authorships"] as? [[String: Any]] ?? []).compactMap { ($0["author"] as? [String: Any])?["display_name"] as? String }
        let ps = names.map(splitName)
        let biblio = m["biblio"] as? [String: Any] ?? [:]
        let fp = biblio["first_page"] as? String ?? "", lp = biblio["last_page"] as? String ?? ""
        let src = (m["primary_location"] as? [String: Any])?["source"] as? [String: Any]
        let doi = (m["doi"] as? String ?? "").replacingOccurrences(of: "https://doi.org/", with: "")
        let year = m["publication_year"] as? Int
        let title = m["display_name"] as? String ?? ""
        let type = m["type"] as? String ?? ""
        let ref = Ref(authors: ps, editors: [], year: year, title: title, container: src?["display_name"] as? String ?? "",
                      volume: biblio["volume"] as? String ?? "", issue: biblio["issue"] as? String ?? "",
                      pages: fp.isEmpty ? "" : (lp.isEmpty || lp == fp ? fp : fp + "-" + lp), doi: doi,
                      publisher: src?["host_organization_name"] as? String ?? "",
                      type: type == "article" ? "journal-article" : type)
        return Work(authors: ps.map { $0.family }, year: year, title: title, type: type, ref: ref)
    }

    static func resolveDOI(_ d: String) async throws -> Work? {
        let enc = d.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? d
        if let j = try await getJSON("https://api.crossref.org/works/" + enc), let m = j["message"] as? [String: Any] {
            let w = crossrefWork(m)
            if !w.authors.isEmpty && w.year != nil { return w }
        }
        if let j = try await getJSON("https://doi.org/" + enc, accept: "application/vnd.citationstyles.csl+json") {
            let w = cslWork(j)
            if !w.authors.isEmpty && w.year != nil { return w }
        }
        return nil
    }

    /// Başlığın sayfada aynen geçmesi ve yazar soyadının sayfada bulunması: başka bir eserle karışmayı önler.
    static func acceptable(_ w: Work, text: String) -> Bool {
        guard !w.authors.isEmpty, let y = w.year, y <= currentYear + 1, !w.title.isEmpty else { return false }
        // Sayfada eserden 15+ yıl sonraki bir yıl geçiyorsa bu başka (eski) bir eserdir
        let maxYear = matches(#"\b(?:19|20)\d{2}\b"#, in: text).compactMap { Int($0) }.filter { $0 <= currentYear }.max() ?? 0
        if y + 15 < maxYear { return false }
        guard containsPhrase(text, w.title) && authorOnPage(w.authors, text) else { return false }
        // Kısa/genel başlıklarda ilk yazar sayfanın başında (ilk 10 satır) görünmeli
        if squash(w.title).count < 20 {
            let top = text.split(separator: "\n").prefix(10).joined(separator: "\n")
            return authorOnPage([w.authors[0]], top)
        }
        return true
    }

    // MARK: Cozumleme

    /// (doi, güvenilir): dosya adındaki SSRN numarası güvenilirdir; sayfa metnindekiler başka eseri işaret edebilir, doğrulanır.
    static func idDOIs(_ page: String, _ filename: String) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        for n in matches(#"(?i)^ssrn[-_ ]?(\d{6,8})"#, in: filename, group: 1) { out.append(("10.2139/ssrn." + n, true)) }
        for n in matches(#"(?i)ssrn\.com/abstract[=_ ]*(\d{6,8})"#, in: page, group: 1) { out.append(("10.2139/ssrn." + n, false)) }
        for n in matches(#"(?i)arxiv:\s*(\d{4}\.\d{4,5})"#, in: page, group: 1) { out.append(("10.48550/arXiv." + n, false)) }
        for n in matches(#"(?i)NBER Working Paper (?:Series )?(?:No\.?\s*)?(\d{3,5})"#, in: page, group: 1) { out.append(("10.3386/w" + n, false)) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.0).inserted }.prefix(3).map { $0 }
    }

    static func isbnValid(_ d: String) -> Bool {
        let c = Array(d.uppercased())
        if c.count == 13, c.allSatisfy({ $0.isNumber }) {
            let sum = c.enumerated().reduce(0) { $0 + (Int(String($1.element)) ?? 0) * ($1.offset % 2 == 0 ? 1 : 3) }
            return sum % 10 == 0
        }
        if c.count == 10 {
            var sum = 0
            for (i, ch) in c.enumerated() {
                let v = (ch == "X" && i == 9) ? 10 : (Int(String(ch)) ?? -100)
                sum += v * (10 - i)
            }
            return sum % 11 == 0
        }
        return false
    }

    static func isbns(_ page: String, _ filename: String) -> [String] {
        var out: [String] = []
        for m in matches(#"(?i)ISBN(?:-1[03])?:?\s*([\dXx\- ]{10,17})"#, in: page + " " + filename, group: 1) {
            out.append(m.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: ""))
        }
        out += matches(#"(?<![\dA-Za-z])(97[89]\d{10})(?![\dA-Za-z])"#, in: filename, group: 1)
        var seen = Set<String>()
        return out.filter { isbnValid($0) && seen.insert($0).inserted }
    }

    static func queries(_ data: PageData) -> [String] {
        func cleanLines(_ page: String) -> [String] {
            Array(page.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.prefix(40).filter { !isJunk($0) }.prefix(10))
        }
        let clean = data.pages.map(cleanLines).first(where: { $0.count >= 2 }) ?? cleanLines(data.pages.first ?? "")
        var out: [String] = []
        let flat = data.text.replacingOccurrences(of: "\n", with: " ")
        if let g = groups(#"^\s*(.{8,200}?)\s+Author\(s\):"#, in: flat) { out.append(g[0]) }                                 // JSTOR kapağı
        if let g = groups(#"Suggested Citation:.{0,200}?\((?:19|20)\d{2}\)\s*:\s*([^,]{6,150})"#, in: flat) { out.append(g[0]) }   // EconStor
        if clean.count >= 2 { out.append(clean.prefix(2).joined(separator: " ")) }
        if clean.count >= 3 { out.append(clean.prefix(3).joined(separator: " ")) }
        for l in clean.prefix(6) where l.count >= 18 { out.append(l) }
        for i in 0..<max(0, min(clean.count, 6) - 1) { out.append(clean[i] + " " + clean[i + 1]) }
        var seen = Set<String>()
        return out.map { String($0.prefix(250)) }.filter { seen.insert($0).inserted }.prefix(8).map { $0 }
    }

    static func lookup(_ data: PageData) async throws -> Found? {
        // 1) Sabit kapak sayfası biçimleri (JSTOR, EconStor, MPRA) ve dosya adındaki "Soyad 2014" kalıbı: yerel ve güvenilir
        if let c = coverParse(data) { return Found(authors: c.0, year: c.1, how: "cover") }
        if useFilename, let g = filenameGuess(data.filename) { return Found(authors: g.0, year: g.1, how: "filename") }

        if onlineEnabled, let f = try await lookupOnline(data) { return f }
        return localFallback(data)
    }

    /// DOI, kimlik, ISBN ve başlık araması. Hiçbir şey bulunamazsa nil; ağ/limit sorununda hata fırlatır.
    static func lookupOnline(_ data: PageData) async throws -> Found? {
        let text = data.text
        let first = data.pages.first ?? ""
        let head = String(first.prefix(1200))
        var degraded = false
        do {
            // 2) Eserin kendi kimliği: SSRN / arXiv / NBER
            for (d, trusted) in idDOIs(first, data.filename) {
                if let w = try await resolveDOI(d), let y = w.year, trusted || acceptable(w, text: text) {
                    return Found(authors: w.authors, year: y, how: "id", ref: w.ref)
                }
            }
            // 3) Metindeki DOI (Crossref, olmazsa doi.org)
            var dois: [String] = []
            for d in matches(#"10\.\d{4,9}/[^\s"<>]+"#, in: text) {
                let t = d.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}"))
                if !dois.contains(t) { dois.append(t) }
            }
            for d in dois.prefix(3) {
                if let w = try await resolveDOI(d), let y = w.year,
                   titleInText(w.title, text) || containsPhrase(text, w.title) || (head.contains(d) && text.count < 1500) {
                    return Found(authors: w.authors, year: y, how: "doi", ref: w.ref)
                }
            }
            // 4) Kitaplar: ISBN -> Open Library
            for isbn in isbns(first, data.filename).prefix(2) {
                if let j = try await getJSON("https://openlibrary.org/api/books?bibkeys=ISBN:\(isbn)&format=json&jscmd=data"),
                   let b = j["ISBN:" + isbn] as? [String: Any],
                   let au = (b["authors"] as? [[String: Any]])?.compactMap({ $0["name"] as? String }), !au.isEmpty,
                   let y = matches(#"(?:19|20)\d{2}"#, in: b["publish_date"] as? String ?? "").compactMap({ Int($0) }).first {
                    let pubs = (b["publishers"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.first ?? ""
                    let r = Ref(authors: au.map(splitName), editors: [], year: y, title: b["title"] as? String ?? "", publisher: pubs, type: "book")
                    return Found(authors: au.compactMap { $0.split(separator: " ").last.map(String.init) }, year: y, how: "isbn", ref: r)
                }
            }
            // 5) Başlık araması (Crossref, sonra OpenAlex)
            for q in queries(data) {
                let enc = encodeQuery(q)
                if let j = try await getJSON("https://api.crossref.org/works?rows=8&select=author,editor,issued,published-print,published-online,title,type,container-title,volume,issue,page,DOI,publisher&query.bibliographic=" + enc),
                   let items = (j["message"] as? [String: Any])?["items"] as? [[String: Any]] {
                    let works = items.map(crossrefWork).sorted { ($0.type == "journal-article" ? 0 : 1) < ($1.type == "journal-article" ? 0 : 1) }
                    if let w = works.first(where: { acceptable($0, text: text) }) { return Found(authors: w.authors, year: w.year!, how: "title", ref: w.ref) }
                }
                do {
                    if let j = try await getJSON("https://api.openalex.org/works?per-page=6&select=display_name,publication_year,authorships,type,doi,biblio,primary_location&search=" + enc),
                       let items = j["results"] as? [[String: Any]] {
                        if let w = items.map(openAlexWork).first(where: { acceptable($0, text: text) }) { return Found(authors: w.authors, year: w.year!, how: "working-paper", ref: w.ref) }
                    }
                } catch EngineError.network { degraded = true }
            }
        }
        if degraded { throw EngineError.network }   // OpenAlex'e ulaşılamadı: atlanmış sayma, sonra tekrar dene
        return nil
    }

    /// İsteğe bağlı tahmin (daha az güvenilir): ilk sayfadaki yazar satırları, PDF yazar alanı
    static func localFallback(_ data: PageData) -> Found? {
        guard guessEnabled else { return nil }
        let first = data.pages.first ?? ""
        if let g = localGuess(first) { return Found(authors: g.0, year: g.1, how: data.ocr ? "ocr+text" : "text") }
        if let meta = data.metaAuthor {
            let top = first.split(separator: "\n").prefix(30).joined(separator: "\n")
            let people = splitPeople(meta.replacingOccurrences(of: ",", with: " and "))
            let s = people.compactMap { surname($0) }.filter { squash($0).count >= 3 && squash(top).contains(squash($0)) }
            if !s.isEmpty, s.count == people.count { return Found(authors: s, year: guessYear(first), how: "pdf-author") }
        }
        return nil
    }

    static func isJunk(_ l: String) -> Bool {
        let low = l.lowercased()
        if l.count < 4 { return true }
        for w in ["http", "www.", "doi", "issn", "contents lists", "journal homepage", "©", "downloaded", "available online",
                  "electronic copy", "working paper", "vol.", "volume", "sciencedirect", "elsevier", "springer", "wiley", "jstor"] {
            if low.contains(w) { return true }
        }
        let digits = l.filter { $0.isNumber }.count
        return Double(digits) / Double(l.count) > 0.25
    }

    /// Apple NaturalLanguage kişi adı etiketleyicisi (cihaz üzerinde çalışır).
    static func nlNames(_ line: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = line
        var out: [String] = []
        tagger.enumerateTags(in: line.startIndex..<line.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            let name = String(line[range])
            if tag == .personalName, name.split(separator: " ").count >= 2 { out.append(name) }
            return true
        }
        return out
    }

    static func nlGuess(_ page: String) -> [String]? {
        let lines = page.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !isJunk($0) }.prefix(20)
        var found: [String] = []
        var hit = false
        for l in lines {
            let low = l.lowercased()
            if affiliationWords.contains(where: { low.contains($0) }) || blockWords.contains(where: { low.contains($0) }) {
                if hit { break } else { continue }
            }
            let cleaned = l.replacingOccurrences(of: #"[*†‡§¶‖\d]+"#, with: " ", options: .regularExpression)
            let names = nlNames(cleaned).filter { n in !n.lowercased().split(separator: " ").contains { titleWords.contains(String($0)) } }
            if names.isEmpty { if hit { break } else { continue } }
            hit = true
            for n in names { if let s = surname(n), !found.contains(s) { found.append(s) } }
        }
        return found.isEmpty ? nil : Array(found.prefix(6))
    }

    // MARK: Kapak sayfasi bicimleri

    static func surnameFromList(_ people: [String]) -> [String] {
        people.compactMap { p in
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if let c = t.firstIndex(of: ",") { return String(t[..<c]).trimmingCharacters(in: .whitespaces) }
            return surname(t)
        }.filter { !$0.isEmpty }
    }

    static func splitPeople(_ s: String) -> [String] {
        var parts = [s]
        for sep in [" and ", " & ", " ve ", ";"] { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func coverParse(_ data: PageData) -> ([String], Int)? {
        let flat = data.text.replacingOccurrences(of: "\n", with: " ")
        // JSTOR kapagi: "Author(s): ... Source: ... Published by:"
        if let g = groups(#"Author\(s\):\s*(.+?)\s+Source:\s*(.+?)(?:\s+Published by:|\s+Stable URL:|$)"#, in: flat) {
            let people = g[0].components(separatedBy: ", ").flatMap { splitPeople($0) }
            if let y = matches(#"(?:19|20)\d{2}"#, in: g[1]).compactMap({ Int($0) }).first(where: { $0 <= currentYear }), !people.isEmpty {
                let s = people.compactMap { surname($0) }
                if !s.isEmpty { return (s, y) }
            }
        }
        // EconStor / benzeri: "Suggested Citation: Soyad, Ad; ... (2013) : Baslik"
        if let g = groups(#"Suggested Citation:\s*(.+?)\s*\(((?:19|20)\d{2})\)"#, in: flat), g[0].count < 220, let y = Int(g[1]) {
            let people = g[0].contains(";") ? g[0].components(separatedBy: ";") : splitPeople(g[0])
            let s = surnameFromList(people.map { $0.replacingOccurrences(of: " et al.", with: "") })
            if !s.isEmpty { return (s, y) }
        }
        // MPRA: "Soyad, Ad and Soyad, Ad and ..."
        if flat.contains("Munich Personal RePEc Archive"), let y = guessYear(data.pages.first ?? "") {
            let re = #"^(?:and )?\p{Lu}[\p{L}'’\-]+, \p{Lu}"#
            let lines = (data.pages.first ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if let start = lines.firstIndex(where: { $0.range(of: re, options: .regularExpression) != nil }) {
                var acc: [String] = []
                var i = start
                while i < lines.count, lines[i].range(of: re, options: .regularExpression) != nil { acc.append(lines[i]); i += 1 }
                let people = acc.joined(separator: " ").components(separatedBy: " and ").map { $0.hasPrefix("and ") ? String($0.dropFirst(4)) : $0 }
                let s = surnameFromList(people)
                if !s.isEmpty { return (s, y) }
            }
        }
        return nil
    }

    // MARK: Ilk sayfadan yazar ve yil tahmini

    static let affiliationWords = ["university", "üniversite", "universit", "institute", "enstitü", "department", "bölüm", "school",
                                   "college", "center", "centre", "faculty", "fakülte", "bank", "@", "bilim dalı", "laboratory",
                                   "research", "institut", "universidad", "ministry", "bakanlığı"]
    static let blockWords = ["abstract", "özet", "working", "paper", "journal", "dergi", "keywords", "introduction", "giriş", "draft",
                             "tezi", "thesis", "danışman", "hazırlayan", "editör", "editor", "series", "discussion", "report", "rapor",
                             "senior", "economist", "professor", "prof.", "director", "researcher", "lecturer", "associate", "fellow", "analyst", "manager", "assistant"]
    /// Baslik satirlarinin "isim listesi" sanilmasini onleyen yaygin baslik sozcukleri.
    static let titleWords: Set<String> = ["jobs", "skills", "green", "energy", "economy", "economic", "policy", "analysis", "impact", "impacts",
                                          "effects", "effect", "labor", "labour", "employment", "growth", "development", "environmental",
                                          "climate", "evidence", "market", "markets", "theory", "model", "models", "review", "study",
                                          "international", "national", "global", "sustainable", "renewable", "innovation", "education", "training"]

    static func guessYear(_ page: String) -> Int? {
        // 1) Dergi künyesi: "Journal of X 101 (2013) 105–114", "Energy Procedia 88 ( 2016 ) 257"
        let top = page.split(separator: "\n").prefix(10).joined(separator: "\n")
        for m in matches(#"\(\s*((?:19|20)\d{2})\s*\)\s*\d"#, in: top, group: 1) {
            if let y = Int(m), y <= currentYear { return y }
        }
        // 2) Tarih ifadeleri: en geç olanı (basım yılı kabul/yayın tarihlerinden önce olamaz)
        let months = "january|february|march|april|may|june|july|august|september|october|november|december|ocak|şubat|mart|nisan|mayıs|haziran|temmuz|ağustos|eylül|ekim|kasım|aralık"
        let patterns = [
            "(?i)\\b(?:\(months))\\b[^A-Za-z0-9]{0,2}[0-9,\\s\\-–]{0,14}?\\b((?:19|20)\\d{2})\\b",
            #"(?i)(?:©|\(c\)|copyright)\s*(?:[A-Za-z ,.()]{0,60})?((?:19|20)\d{2})"#,
            #"(?i)(?:received|accepted|published|available online|revised|submitted)[^\n]{0,40}?\b((?:19|20)\d{2})\b"#,
            #"(?m)^[^\n]{0,30}[–—-]\s*((?:19|20)\d{2})\s*$"#,
        ]
        var years: [Int] = []
        for p in patterns { years += matches(p, in: page, group: 1).compactMap { Int($0) }.filter { $0 <= currentYear } }
        return years.max()
    }

    static func nameParts(_ raw: String) -> [String]? {
        let low = raw.lowercased()
        if affiliationWords.contains(where: { low.contains($0) }) || blockWords.contains(where: { low.contains($0) }) { return nil }
        if raw.contains(where: { $0.isNumber }) { return nil }
        var parts = [raw]
        for sep in [" and ", " & ", " ve ", ",", ";"] { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        for p in parts {
            let toks = p.split(separator: " ").map(String.init)
            guard (2...4).contains(toks.count) else { return nil }
            for t in toks {
                guard t.range(of: #"^\p{Lu}[\p{L}'’.\-]*$"#, options: .regularExpression) != nil else { return nil }
            }
            if toks.count >= 3 && toks.allSatisfy({ $0 == $0.uppercased() }) { return nil }
        }
        return parts
    }

    static func surname(_ person: String) -> String? {
        let toks = person.split(separator: " ").map(String.init).filter { $0.replacingOccurrences(of: ".", with: "").count >= 2 }
        guard !toks.isEmpty else { return nil }
        let caps = toks.filter { $0 == $0.uppercased() && $0.count > 1 }
        if caps.count == 1 && toks.count > 1 { return caps[0] }
        return toks.last
    }

    /// "a UCLA Institute…", "a,bSchool…" gibi kurum satırlarından üst indis etiketlerini (a, b, c…) toplar.
    static func affLabels(_ page: String) -> Set<Character> {
        var out = Set<Character>()
        for l in page.split(separator: "\n") {
            if let g = groups(#"^([a-h](?:\s*,\s*[a-h])*)\s*\p{Lu}"#, in: String(l)) { for c in g[0] where c.isLetter { out.insert(c) } }
        }
        return out
    }

    /// Yazar satırındaki dipnot/kurum işaretlerini, yapışık üst indis harflerini ve Jr./III eklerini temizler.
    static func cleanAuthorLine(_ raw: String, labels: Set<Character>, page: String) -> String {
        var line = raw.replacingOccurrences(of: #"[*†‡§¶‖⁎✉☆∗·•]+"#, with: ",", options: .regularExpression)
        line = line.replacingOccurrences(of: #"(?<=\p{L})\d+"#, with: "", options: .regularExpression)
        var out: [String] = []
        for tok in line.split(separator: " ").map(String.init) {
            if tok.allSatisfy({ "abcdefgh,".contains($0) }) { continue }            // "a,b," gibi yalnız etiketler
            var core = tok, punct = ""
            while let l = core.last, ",;".contains(l) { punct = String(l) + punct; core.removeLast() }
            if labels.contains(where: { core.last == $0 }), core.count >= 4,
               page.components(separatedBy: core).count - 1 == 1 {                    // sayfada yalnız bir kez geçiyorsa etiket yapışmıştır
                core.removeLast()
            }
            if ["Jr", "Jr.", "Sr", "Sr.", "II", "III", "IV"].contains(core) { continue }
            out.append(core + punct)
        }
        return out.joined(separator: " ")
    }

    static func localGuess(_ page: String) -> ([String], Int?)? {
        let year = guessYear(page)
        let lines = page.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let head = Array(lines.prefix(60))
        let labels = affLabels(page)
        var authors: [String] = []
        for (i, rawLine) in head.enumerated() {
            // dipnot isaretlerini temizle, "By " onekini ve satir sonu rakamlarini at
            var line = cleanAuthorLine(rawLine, labels: labels, page: page)
            var byCue = false
            if line.range(of: #"^(?i)by\s+"#, options: .regularExpression) != nil {
                byCue = true
                line = line.replacingOccurrences(of: #"^(?i)by\s+"#, with: "", options: .regularExpression)
            }
            line = line.replacingOccurrences(of: #"\d+$"#, with: "", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            guard let people = nameParts(line) else { continue }
            let prev = i > 0 ? head[i - 1].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": ")) : ""
            let cue = byCue || ["hazırlayan", "yazar", "author", "authors", "by", "tarafından"].contains(prev)
            let next = head[(i + 1)..<min(i + 3, head.count)].joined(separator: " ").lowercased()
            let affiliated = affiliationWords.contains { next.contains($0) }
            let list = i < 14 && people.count >= 2 && !people.contains { p in p.lowercased().split(separator: " ").contains { titleWords.contains(String($0)) } }
            if cue || affiliated || list {
                for p in people { if let s = surname(p), !authors.contains(s) { authors.append(s) } }
            }
        }
        authors = Array(authors.prefix(6))
        return authors.isEmpty ? nil : (authors, year)
    }

    static func filenameGuess(_ name: String) -> ([String], Int)? {
        let stem = name.precomposedStringWithCanonicalMapping.replacingOccurrences(of: ".pdf", with: "", options: [.caseInsensitive, .anchored, .backwards]).replacingOccurrences(of: "_", with: " ")
        guard let g = groups(#"^(\p{Lu}[\p{L}'’\-]+(?:\s*(?:,|&|and)\s*\p{Lu}[\p{L}'’\-]+){0,3})\s*[-–]?\s*((?:19|20)\d{2})\b"#, in: stem),
              let y = Int(g[1]), y <= currentYear else { return nil }
        let people = g[0].components(separatedBy: CharacterSet(charactersIn: ",&")).flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let bad = people.contains { p in blockWords.contains(p.lowercased()) || titleWords.contains(p.lowercased()) || ["annual", "table", "figure", "chapter", "notes"].contains(p.lowercased()) }
        let acronym = people.contains { $0.count < 3 || $0 == $0.uppercased() }
        return (people.isEmpty || bad || acronym) ? nil : (people, y)
    }

    // MARK: Adlandirma

    static func baseName(_ authors: [String], _ year: Int?) -> String? {
        let n = Namer.render(NameFields(authors: authors, year: year), prefs: NamingPrefs())
        return authors.isEmpty ? nil : n
    }

    /// "Garcia Vaquero et al - 2021a" -> ("Garcia Vaquero", 2021)
    static func parseNamed(_ stem: String) -> (first: String, year: Int?)? {
        guard let g = groups(#"^(.+?) - ((?:19|20)\d{2}|xxxx)[a-z]?$"#, in: stem) else { return nil }
        var a = g[0]
        for sep in [" et al", " & "] { if let r = a.range(of: sep) { a = String(a[..<r.lowerBound]) } }
        return (a, Int(g[1]))
    }

    static func alreadyNamed(_ stem: String) -> Bool {
        stem.range(of: #"^.+ - ((19|20)\d{2}|xxxx)[a-z]?$"#, options: .regularExpression) != nil
    }
}

enum Apa {
    /// Sıfat/ülke/kurum gibi büyük harfle kalması gereken yaygın sözcükler (cümle düzenine çevirirken korunur)
    static let keep: Set<String> = ["English", "German", "French", "Italian", "Spanish", "Turkish", "Chinese", "Japanese", "Indian", "Russian",
        "European", "American", "African", "Asian", "Latin", "Nordic", "British", "Canadian", "Australian", "Europe", "America", "Africa",
        "Asia", "China", "India", "Turkey", "Germany", "France", "Italy", "Spain", "Japan", "Brazil", "Mexico", "Canada", "Australia",
        "Korea", "Korean", "Poland", "Polish", "Dutch", "Netherlands", "Greece", "Greek", "Thailand",
        "Romania", "Hungary", "Portugal", "Sweden", "Finland", "Denmark", "Norway", "Africa", "Pacific", "Atlantic",
        "Marxist", "Keynesian", "Bayesian", "Gaussian", "Nobel", "Covid-19"]

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] { t = t.replacingOccurrences(of: a, with: b) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "☆*†‡ \n\t"))
        return t.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
    }

    static func initials(_ given: String) -> String {
        let parts = given.replacingOccurrences(of: ".", with: ". ").split(separator: " ").map(String.init)
        var out: [String] = []
        for p in parts {
            if p.contains("-") {
                out.append(p.split(separator: "-").compactMap { $0.first }.map { "\(String($0).uppercased())." }.joined(separator: "-"))
            } else if let f = p.first, f.isLetter {
                out.append("\(String(f).uppercased()).")
            }
        }
        return out.joined(separator: " ")
    }

    static func name(_ p: Person) -> String {
        let i = initials(p.given)
        return i.isEmpty ? clean(p.family) : "\(clean(p.family)), \(i)"
    }

    static func authorList(_ ps: [Person]) -> String {
        let n = ps.map(name)
        switch n.count {
        case 0: return ""
        case 1: return n[0]
        case 2...20: return n.dropLast().joined(separator: ", ") + ", & " + n.last!
        default: return n.prefix(19).joined(separator: ", ") + ", . . . " + n.last!
        }
    }

    static func lowerFirstLetter(_ w: String) -> String {
        guard let i = w.firstIndex(where: { $0.isLetter }) else { return w }
        return String(w[..<i]) + String(w[i]).lowercased() + String(w[w.index(after: i)...])
    }

    /// Başlık Title Case ise APA'nın istediği cümle düzenine çevirir; özel adlar (Apple NL), kısaltmalar ve ülke/sıfat sözcükleri korunur.
    static func sentenceCase(_ t: String) -> String {
        let words = t.split(separator: " ").map(String.init)
        let content = words.filter { $0.filter({ $0.isLetter }).count > 3 }
        guard content.count >= 3 else { return t }
        let capped = content.filter { $0.first(where: { $0.isLetter })?.isUppercase == true }.count
        guard Double(capped) / Double(content.count) >= 0.6 else { return t }   // zaten cümle düzeninde

        var prot = Set<String>()
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = t
        tagger.enumerateTags(in: t.startIndex..<t.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, r in
            if let tag, [NLTag.personalName, .placeName, .organizationName].contains(tag) {
                for w in t[r].split(separator: " ") { prot.insert(String(w)) }
            }
            return true
        }
        var out: [String] = []
        for (i, w) in words.enumerated() {
            let letters = w.filter { $0.isLetter }
            let afterBreak = i == 0 || [":", "?", "!", ".", "–", "—"].contains(where: { words[i - 1].hasSuffix($0) }) || ["–", "—", "-"].contains(words[i - 1])
            let core = w.trimmingCharacters(in: .punctuationCharacters)
            let innerCaps = w.dropFirst().contains(where: { $0.isUppercase }) && w.contains(where: { $0.isLowercase })
            if afterBreak || prot.contains(core) || keep.contains(core) || (letters.count >= 2 && w == w.uppercased()) || w.contains(where: { $0.isNumber }) || innerCaps || letters.count == 1 && w.first?.isUppercase == true && words.count > 1 && letters.first == "I" {
                if i > 0 && afterBreak, let f = w.firstIndex(where: { $0.isLetter }) {
                    out.append(String(w[..<f]) + String(w[f]).uppercased() + String(w[w.index(after: f)...]))
                } else { out.append(w) }
            } else {
                // tireli sözcük: ilk parça kuralla, sonrakiler küçük (kısaltma değilse)
                let parts = w.components(separatedBy: "-")
                out.append(parts.enumerated().map { j, p in (j > 0 && p == p.uppercased() && p.count > 1) ? p : lowerFirstLetter(p) }.joined(separator: "-"))
            }
        }
        return out.joined(separator: " ")
    }

    /// APA: iki noktadan sonraki ilk sözcük büyük harfle; "?:" yerine "?".
    static func fixTitle(_ t: String) -> String {
        var x = sentenceCase(t).replacingOccurrences(of: "?:", with: "?").replacingOccurrences(of: "!:", with: "!")
        if let re = try? NSRegularExpression(pattern: #"(:\s+)(\p{Ll})"#) {
            let ns = x as NSString
            for m in re.matches(in: x, range: NSRange(location: 0, length: ns.length)).reversed() {
                let r = m.range(at: 2)
                x = (x as NSString).replacingCharacters(in: r, with: ns.substring(with: r).uppercased())
            }
        }
        return x
    }

    static func journalCase(_ s: String) -> String {
        let c = clean(s)
        return (c == c.uppercased() || c == c.lowercased()) ? c.capitalized : c
    }

    static func doiURL(_ d: String) -> String {
        let t = d.replacingOccurrences(of: "https://doi.org/", with: "").replacingOccurrences(of: "http://dx.doi.org/", with: "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "" : "https://doi.org/" + t
    }

    static func ending(_ s: String) -> String { (s.last.map { ".?!".contains($0) } ?? true) ? s : s + "." }

    static func format(_ r: Ref) -> String {
        let authors = authorList(r.authors)
        let title = clean(r.title)
        let date = "(\(r.year.map(String.init) ?? "n.d."))."
        let doi = doiURL(r.doi)
        let isJournal = r.type == "journal-article" && !clean(r.container).isEmpty
        let isChapter = (r.type == "book-chapter" || r.type == "chapter") && !clean(r.container).isEmpty
        var parts: [String] = []
        if !authors.isEmpty { parts.append(ending(authors)) }

        if isJournal {
            if authors.isEmpty { parts.append(ending(fixTitle(title))); parts.append(date) } else { parts.append(date); parts.append(ending(fixTitle(title))) }
            var src = "*\(journalCase(r.container))*"
            if !r.volume.isEmpty { src += ", *\(r.volume)*" }
            if !r.issue.isEmpty { src += "(\(r.issue))" }
            if !r.pages.isEmpty { src += ", \(r.pages.replacingOccurrences(of: "-", with: "–"))" }
            parts.append(src + ".")
        } else if isChapter {
            parts.append(date)
            parts.append(ending(fixTitle(title)))
            let eds = r.editors.map { p -> String in let i = initials(p.given); return i.isEmpty ? clean(p.family) : "\(i) \(clean(p.family))" }
            var inPart = "In "
            if !eds.isEmpty {
                inPart += (eds.count == 1 ? eds[0] : eds.dropLast().joined(separator: ", ") + (eds.count > 2 ? "," : "") + " & " + eds.last!) + (eds.count == 1 ? " (Ed.), " : " (Eds.), ")
            }
            inPart += "*\(clean(r.container))*"
            if !r.pages.isEmpty { inPart += " (pp. \(r.pages.replacingOccurrences(of: "-", with: "–")))" }
            parts.append(inPart + ".")
            if !clean(r.publisher).isEmpty { parts.append(ending(clean(r.publisher))) }
        } else {
            // kitap, rapor, çalışma kağıdı, bildiri: başlık italik
            if authors.isEmpty { parts.append("*\(ending(fixTitle(title)))*"); parts.append(date) } else { parts.append(date); parts.append("*\(ending(fixTitle(title)))*") }
            if !clean(r.publisher).isEmpty { parts.append(ending(clean(r.publisher))) }
        }
        if !doi.isEmpty { parts.append(doi) }
        return parts.joined(separator: " ").replacingOccurrences(of: "  ", with: " ")
    }
}

enum Flag {
    static let prefix = "!! "   // çözülemeyen dosyalar: klasör listesinin en üstünde sıralanır
    static func strip(_ s: String) -> String { s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s }
}

enum Outcome {
    case flagged(from: URL, to: URL, why: String)   // çözülemedi: ada uyarı öneki eklendi
    case renamed(from: URL, to: URL, how: String, entry: RefEntry)
    case skipped(URL, String)
    case pending(URL, String)
    case kunye(URL, RefEntry)   // dosya adı zaten doğru: yalnızca künye üretildi
}

actor Processor {
    private var reserved = Set<String>()
    private let fm = FileManager.default

    private func exists(_ dir: URL, _ stem: String) -> Bool {
        let p = dir.appendingPathComponent(stem + ".pdf").path
        return fm.fileExists(atPath: p) || reserved.contains(p.lowercased())
    }

    /// Aynı ada sahip dosya varsa yıla harf eklenir (2013b, 2013c…).
    private func uniqueStem(_ dir: URL, _ f: NameFields, _ prefs: NamingPrefs) -> String {
        let base = Namer.render(f, prefs: prefs)
        let letters = Array("abcdefghijklmnopqrstuvwxyz").map(String.init)
        let any = exists(dir, base) || letters.contains { exists(dir, Namer.render(f, prefs: prefs, suffix: $0)) }
        if !any { return base }
        for l in letters.dropFirst() {
            let n = Namer.render(f, prefs: prefs, suffix: l)
            if !exists(dir, n) { return n }
        }
        return base + "-" + UUID().uuidString.prefix(4)
    }

    /// Elle girilen bilgiyle yeniden adlandırır (otomatik çözülemeyen dosyalar için).
    func renameManual(_ url: URL, authors: [String], year: Int?, ref: Ref, entry: RefEntry) -> Outcome {
        guard fm.fileExists(atPath: url.path) else { return .skipped(url, Loc.t("file not found")) }
        let fields = NameFields(authors: authors, year: year, title: ref.title, journal: ref.container, doi: ref.doi)
        let dir = url.deletingLastPathComponent()
        let prefs = Engine.naming
        let base = Namer.render(fields, prefs: prefs)
        if url.lastPathComponent.lowercased() == (base + ".pdf").lowercased() { return .kunye(url, entry) }   // ad zaten bu: yalnızca künye
        let stem = uniqueStem(dir, fields, prefs)
        let dest = dir.appendingPathComponent(stem + ".pdf")
        reserved.insert(dest.path.lowercased())
        do { try fm.moveItem(at: url, to: dest) } catch { return .skipped(url, Loc.t("error: %@", error.localizedDescription)) }
        return .renamed(from: url, to: dest, how: "manual", entry: entry)
    }

    /// Çözülemeyen dosyanın adının başına "!! " ekler (zaten ekliyse dokunmaz).
    private func flag(_ url: URL, _ why: String) -> Outcome {
        guard !url.lastPathComponent.hasPrefix(Flag.prefix) else { return .skipped(url, why) }
        let dir = url.deletingLastPathComponent()
        var dest = dir.appendingPathComponent(Flag.prefix + url.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(Flag.prefix + url.deletingPathExtension().lastPathComponent + " (\(n)).pdf"); n += 1
        }
        do { try fm.moveItem(at: url, to: dest) } catch { return .skipped(url, why) }
        return .flagged(from: url, to: dest, why: why)
    }

    private func pendingReason() -> String { Engine.lastIssue.isEmpty ? Loc.t("network/limit problem") : Engine.lastIssue }

    /// `evaluate`: ölçüm modu. Zaten adlandırılmış dosyayı da çözümler, benzersizleştirme yapmaz, dosyaya dokunmaz.
    func process(_ url: URL, dryRun: Bool = false, evaluate: Bool = false) async -> Outcome {
        guard url.pathExtension.lowercased() == "pdf" else { return .skipped(url, Loc.t("not a PDF")) }
        let stem0 = url.deletingPathExtension().lastPathComponent
        if !evaluate && Engine.alreadyNamed(stem0) {
            // Adı zaten doğru: dosyaya dokunmadan yalnızca künyeyi üret (yayın bilgisi dosya adıyla uyuşuyorsa)
            guard Engine.onlineEnabled else { return .skipped(url, Loc.t("already named (online lookup is needed for the reference)")) }
            guard let n = Engine.parseNamed(stem0) else { return .skipped(url, Loc.t("already named")) }
            let d = Engine.read(url)
            if d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .skipped(url, Loc.t("text could not be read")) }
            do {
                if let o = try await Engine.lookupOnline(d), let r = o.ref,
                   Engine.squash(o.authors.first ?? "") == Engine.squash(n.first),
                   n.year == nil || o.year == nil || abs(n.year! - o.year!) <= 1 {
                    return .kunye(url, RefEntry(ref: r))
                }
                return .skipped(url, Loc.t("reference not found (publication data did not match the file name)"))
            } catch { return .pending(url, pendingReason()) }
        }
        let data = Engine.read(url)
        if data.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return evaluate || dryRun ? .skipped(url, Loc.t("text could not be read")) : flag(url, Loc.t("text could not be read")) }
        let found: Found?
        do { found = try await Engine.lookup(data) } catch { return .pending(url, pendingReason()) }   // ağ/limit: sonra tekrar denenir
        guard let f = found, !f.authors.isEmpty else {
            let why = Engine.onlineEnabled ? Loc.t("could not resolve, rename manually") : Loc.t("could not resolve (online lookup is off)")
            return evaluate || dryRun ? .skipped(url, why) : flag(url, why)
        }
        // Künye: kapak/dosya adı/tahmin gibi tam bilgi vermeyen kaynaklarda çevrimiçi eşleşme yalnızca ilk yazar ve yıl tutuyorsa kullanılır
        var ref = f.ref
        if ref == nil && Engine.onlineEnabled && !evaluate, let o = try? await Engine.lookupOnline(data), let r = o.ref,
           Engine.squash(f.authors.first ?? "") == Engine.squash(o.authors.first ?? ""),
           f.year == nil || o.year == nil || abs(f.year! - o.year!) <= 1 {
            ref = r
        }
        let entry = ref.map { RefEntry(ref: $0) } ?? RefEntry(text: Cite.minimal(authors: f.authors, year: f.year),
                                                              key: "m:" + Engine.squash(f.authors.joined()) + "|\(f.year ?? 0)")
        let fields = NameFields(authors: f.authors, year: f.year, title: ref?.title ?? "", journal: ref?.container ?? "", doi: ref?.doi ?? "")
        let dir = url.deletingLastPathComponent()
        let prefs = evaluate ? NamingPrefs() : Engine.naming
        let base = Namer.render(fields, prefs: prefs)
        // Dosya zaten tam bu adı taşıyorsa yeniden adlandırma gerekmez
        if !evaluate && url.lastPathComponent.lowercased() == (base + ".pdf").lowercased() { return .kunye(url, entry) }
        let stem = evaluate ? base : uniqueStem(dir, fields, prefs)
        let dest = dir.appendingPathComponent(stem + ".pdf")
        reserved.insert(dest.path.lowercased())
        if !dryRun && !evaluate {
            do { try fm.moveItem(at: url, to: dest) } catch { return .skipped(url, Loc.t("error: %@", error.localizedDescription)) }
        }
        return .renamed(from: url, to: dest, how: f.how, entry: entry)
    }
}
