import Foundation
import CryptoKit

/// Kaynakça listesindeki bir eserin bulunan sürümleri (makale, çalışma kâğıdı/preprint…)
struct RefVersion {
    var label: String       // "article", "working paper/preprint" … (İngilizce anahtar; gösterimde çevrilir)
    var pdf: URL?           // açık erişimli doğrudan PDF bağlantısı
    var year: Int?
    var isPublished: Bool { label.hasPrefix("article") }
}

struct RefResult {
    var title: String
    var doi: String?
    var year: Int?
    var versions: [RefVersion]
    var landing: URL?       // makalenin sayfası (https://doi.org/…)
    var openAlexDown = false
}

enum Biblio {
    // MARK: Kaynakça dosyasını okuma (.docx, .txt)

    static func entries(from url: URL) -> [String] {
        let raw = url.pathExtension.lowercased() == "docx" ? docxParagraphs(url) : txtEntries(url)
        let skip = ["kaynakça", "kaynaklar", "references", "bibliography", "kaynakca"]
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 25 && !skip.contains($0.lowercased()) && $0.range(of: #"(?:19|20)\d{2}|\(n\.d\.\)"#, options: .regularExpression) != nil }
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func docxParagraphs(_ url: URL) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path, "word/document.xml"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let xml = String(decoding: data, as: UTF8.self)
        guard let para = try? NSRegularExpression(pattern: #"<w:p[ >].*?</w:p>"#, options: [.dotMatchesLineSeparators]),
              let run = try? NSRegularExpression(pattern: #"<w:t(?: [^>]*)?>([^<]*)</w:t>|<w:tab/>|<w:br/>"#) else { return [] }
        let ns = xml as NSString
        return para.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map { m in
            let ps = ns.substring(with: m.range) as NSString
            var text = ""
            for r in run.matches(in: ps as String, range: NSRange(location: 0, length: ps.length)) {
                if r.range(at: 1).location != NSNotFound { text += ps.substring(with: r.range(at: 1)) } else { text += " " }
            }
            return unescape(text)
        }
    }

    static func txtEntries(_ url: URL) -> [String] {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return [] }
        let t = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = t.components(separatedBy: "\n\n").map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }.filter { !$0.isEmpty }
        if blocks.count > 1 { return blocks }
        // boş satır yoksa: girintili (asılı) satırlar öncekine eklenir, diğer her satır ayrı kaynak
        var out: [String] = []
        for line in t.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if let f = line.first, f == " " || f == "\t", !out.isEmpty { out[out.count - 1] += " " + line.trimmingCharacters(in: .whitespaces) }
            else { out.append(line.trimmingCharacters(in: .whitespaces)) }
        }
        return out
    }

    // MARK: Çözümleme

    static func cleaned(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "*", with: "")
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)\bdoi:?\s*\S+"#, with: " ", options: .regularExpression)
        return t.split(separator: " ").joined(separator: " ")
    }

    static func firstDOI(_ s: String) -> String? {
        Engine.matches(#"10\.\d{4,9}/[^\s"<>]+"#, in: s).first?.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}"))
    }

    /// Kaynakça satırı Crossref adayıyla uyuşuyor mu: başlık aynen, ilk yazar soyadı ve yıl (±1) satırda geçmeli.
    static func matches(_ w: Engine.Work, entry: String) -> Bool {
        guard let y = w.year, !w.authors.isEmpty, Engine.containsPhrase(entry, w.title), Engine.authorOnPage([w.authors[0]], entry) else { return false }
        let years = Engine.matches(#"(?:19|20)\d{2}"#, in: entry).compactMap { Int($0) }
        return years.isEmpty || years.contains { abs($0 - y) <= 1 }
    }

    static func label(forType t: String) -> String {
        switch t {
        case "article", "journal-article": return "article"
        case "preprint", "posted-content": return "working paper/preprint"
        case "report", "working-paper": return "working paper/report"
        case "book-chapter": return "book chapter"
        case "book": return "book"
        default: return t.isEmpty ? "version" : t
        }
    }

    static func versions(from item: [String: Any]) -> [RefVersion] {
        let year = item["publication_year"] as? Int
        let def = label(forType: item["type"] as? String ?? "")
        var out: [RefVersion] = []
        for loc in item["locations"] as? [[String: Any]] ?? [] {
            guard let s = loc["pdf_url"] as? String, let u = URL(string: s) else { continue }
            let lab: String
            switch loc["version"] as? String ?? "" {
            case "publishedVersion": lab = "article"
            case "acceptedVersion": lab = "article (accepted version)"
            case "submittedVersion": lab = "working paper/preprint"
            default: lab = def
            }
            out.append(RefVersion(label: lab, pdf: u, year: year))
        }
        if out.isEmpty, let best = item["best_oa_location"] as? [String: Any], let s = best["pdf_url"] as? String, let u = URL(string: s) {
            out.append(RefVersion(label: def, pdf: u, year: year))
        }
        return out
    }

    static func resolve(_ raw: String) async throws -> RefResult? {
        let entry = cleaned(raw)
        // 1) Crossref: DOI varsa doğrudan, yoksa tüm künyeyi sorgu olarak ver ve doğrula
        var found: Engine.Work?
        if let d = firstDOI(raw), let w = try await Engine.resolveDOI(d) { found = w }
        if found == nil {
            let enc = Engine.encodeQuery(String(entry.prefix(300)))
            if let j = try await Engine.getJSON("https://api.crossref.org/works?rows=6&select=author,editor,issued,published-print,published-online,title,type,container-title,volume,issue,page,DOI,publisher&query.bibliographic=" + enc),
               let items = (j["message"] as? [String: Any])?["items"] as? [[String: Any]] {
                let works = items.map(Engine.crossrefWork).sorted { ($0.type == "journal-article" ? 0 : 1) < ($1.type == "journal-article" ? 0 : 1) }
                found = works.first { matches($0, entry: entry) }
            }
        }
        guard let w = found, let ref = w.ref, !w.title.isEmpty else { return nil }
        let doi = ref.doi.isEmpty ? nil : ref.doi
        var result = RefResult(title: w.title, doi: doi, year: w.year, versions: [], landing: doi.flatMap { URL(string: "https://doi.org/" + $0) })

        // 2) OpenAlex: aynı başlıklı tüm sürümler (makale + çalışma kâğıdı/preprint) ve açık erişimli PDF bağlantıları
        do {
            let enc = Engine.encodeQuery(w.title)
            if let j = try await Engine.getJSON("https://api.openalex.org/works?per-page=10&search=\(enc)&select=id,doi,display_name,type,publication_year,authorships,best_oa_location,locations"),
               let items = j["results"] as? [[String: Any]] {
                let want = Engine.norm(w.title), a0 = Engine.squash(w.authors[0])
                var seen = Set<String>()
                for it in items {
                    let ow = Engine.openAlexWork(it)
                    guard Engine.norm(ow.title) == want, let first = ow.authors.first, Engine.squash(first).count >= 3,
                          a0.contains(Engine.squash(first)) || Engine.squash(first).contains(a0) else { continue }
                    for v in versions(from: it) where seen.insert(v.pdf!.absoluteString).inserted { result.versions.append(v) }
                }
            }
        } catch EngineError.network { result.openAlexDown = true }
        result.versions = Array(result.versions.prefix(4))
        return result
    }

    /// Aynı PDF farklı bağlantılardan (yayıncı, NBER, doi.org) gelebilir: içeriğe göre ayırt etmek için.
    static func fingerprint(_ url: URL) -> String {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return UUID().uuidString }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: İndirme (yalnızca açık erişimli doğrudan PDF bağlantıları)

    static func downloadPDF(_ url: URL, into folder: URL, stem: String) async -> URL? {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("Mozilla/5.0 (Macintosh) Biblio/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/pdf,*/*", forHTTPHeaderField: "Accept")
        do {
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let h = try FileHandle(forReadingFrom: tmp)
            let head = h.readData(ofLength: 5)
            try? h.close()
            let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size]) as? Int ?? 0
            guard head == Data("%PDF-".utf8), size > 20_000 else { return nil }   // PDF değil (giriş/abonelik sayfası) ya da çok küçük
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var dest = folder.appendingPathComponent(stem + ".pdf")
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) { dest = folder.appendingPathComponent("\(stem)-\(n).pdf"); n += 1 }
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        } catch { return nil }
    }
}
