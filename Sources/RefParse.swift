import Foundation

/// Elle yazılmış/yapıştırılmış APA benzeri bir künyeyi alanlara ayırır (yerel, internetsiz).
/// Örnek: "Becker, G. S. (1965). A Theory of the Allocation of Time. The economic journal, 75(299), 493-517"
enum RefParse {
    struct Parsed {
        var authors = ""      // her satır: "Soyad, Ad"
        var year = ""
        var type = ""
        var title = ""
        var container = ""
        var volume = ""
        var issue = ""
        var pages = ""
        var doi = ""
        var publisher = ""
    }

    private static func rx(_ p: String, _ s: String, _ g: Int = 0) -> String? {
        guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              g < m.numberOfRanges, let r = Range(m.range(at: g), in: s) else { return nil }
        return String(s[r])
    }

    static func parse(_ raw: String) -> Parsed? {
        var s = raw.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\u{2013}", with: "-").replacingOccurrences(of: "\u{2014}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var out = Parsed()

        // DOI
        if let d = rx(#"10\.\d{4,9}/[^\s"<>]+"#, s) {
            out.doi = d.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}"))
            s = s.replacingOccurrences(of: d, with: "")
            s = s.replacingOccurrences(of: #"(https?://(dx\.)?doi\.org/?|doi:\s*)"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))

        // Yıl: "(1965)" ya da "(1965a)"; yoksa "(n.d.)"
        var authorPart = "", rest = ""
        if let re = try? NSRegularExpression(pattern: #"\(\s*((?:1[0-9]|20)\d{2})[a-z]?\s*\)|\(\s*n\.d\.\s*\)"#),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) {
            if let y = rx(#"\d{4}"#, String(s[r])) { out.year = y }
            authorPart = String(s[..<r.lowerBound])
            rest = String(s[r.upperBound...])
        } else if let y = rx(#"\b(1[5-9]\d{2}|20\d{2})\b"#, s, 1), let r = s.range(of: y) {
            out.year = y
            authorPart = String(s[..<r.lowerBound]); rest = String(s[r.upperBound...])
        } else {
            return nil
        }

        out.authors = authors(from: authorPart)

        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " .,;)(-"))
        guard !rest.isEmpty else { return out }

        // Başlık: ilk cümle sonu (tek harf+nokta kısaltmaları cümle sonu sayılmaz)
        let chars = Array(rest)
        var cut: Int? = nil
        for i in 0..<chars.count where ".?!".contains(chars[i]) {
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            guard next == " " else { continue }
            if chars[i] == ".", i >= 1, chars[i - 1].isLetter, i < 2 || !chars[i - 2].isLetter, chars[i - 1].isUppercase { continue }
            cut = i; break
        }
        var title = rest, after = ""
        if let c = cut {
            title = String(chars[..<(chars[c] == "." ? c : c + 1)])
            after = String(chars[(c + 1)...])
        }
        out.title = title.trimmingCharacters(in: .whitespaces)
        after = after.trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))
        guard !after.isEmpty else { return out }

        // Dergi makalesi: Dergi, cilt(sayı), sayfalar
        if let j = rx(#"^(.+?),\s*(\d+)\s*(?:\(\s*([^)]*?)\s*\))?\s*,\s*([A-Za-z]?\d[\w-]*(?:\s*-\s*[A-Za-z]?\d[\w]*)?)"#, after, 0), !j.isEmpty {
            out.container = rx(#"^(.+?),\s*\d+"#, j, 1) ?? ""
            out.volume = rx(#",\s*(\d+)\s*(?:\(|,)"#, j, 1) ?? ""
            out.issue = rx(#"\(\s*([^)]*?)\s*\)"#, j, 1) ?? ""
            out.pages = (rx(#"\)?\s*,\s*([A-Za-z]?\d[\w-]*(?:\s*-\s*[A-Za-z]?\d[\w]*)?)\s*$"#, j, 1) ?? "").replacingOccurrences(of: " ", with: "")
            out.type = "journal-article"
            return out
        }
        // Dergi, cilt (sayfa yok)
        if let j = rx(#"^(.+?),\s*(\d+)\s*(?:\(\s*([^)]*?)\s*\))?\s*$"#, after, 0) {
            out.container = rx(#"^(.+?),\s*\d+"#, j, 1) ?? ""
            out.volume = rx(#",\s*(\d+)"#, j, 1) ?? ""
            out.issue = rx(#"\(\s*([^)]*?)\s*\)"#, j, 1) ?? ""
            out.type = "journal-article"
            return out
        }
        // Kitap bölümü: In Editör (Ed.), Kitap (pp. 1-20). Yayıncı
        if after.lowercased().hasPrefix("in ") {
            let body = String(after.dropFirst(3))
            if let t = rx(#"\((?:eds?\.?)\)\s*,?\s*(.+?)\s*(?:\(\s*(?:pp?\.)\s*([\d-]+)\s*\))?\s*(?:\.\s*(.*))?$"#, body, 1) { out.container = t }
            out.pages = rx(#"pp?\.\s*([\d]+\s*-\s*[\d]+)"#, body, 1)?.replacingOccurrences(of: " ", with: "") ?? ""
            out.publisher = rx(#"\)\.\s*([^.]+)\.?\s*$"#, body, 1) ?? ""
            out.type = "book-chapter"
            return out
        }
        // Çalışma kâğıdı / rapor
        if rx(#"working paper|discussion paper|technical report|report|nber|ssrn|preprint"#, after) != nil {
            out.publisher = after.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            out.type = "report"
            return out
        }
        // Aksi halde kitap: kalan kısım yayıncı
        out.publisher = after.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        out.type = "book"
        return out
    }

    /// "Conley, T. G., & Taber, C. R." -> "Conley, T. G.\nTaber, C. R."
    static func authors(from part: String) -> String {
        var a = part.replacingOccurrences(of: "&", with: ",").replacingOccurrences(of: "…", with: ",")
            .replacingOccurrences(of: "...", with: ",")
        a = a.replacingOccurrences(of: #"\s+\band\b\s+"#, with: ", ", options: [.regularExpression, .caseInsensitive])
        a = a.replacingOccurrences(of: #"\bet al\.?"#, with: "", options: [.regularExpression, .caseInsensitive])
        let toks = a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if toks.isEmpty { return "" }
        // "Soyad, Ad" çiftleri; virgülsüz yazım ("Matthew E. Kahn") için her parça ayrı kişi
        let hasInitialsStyle = toks.count >= 2 && toks.enumerated().contains { $0.offset % 2 == 1 && looksGiven($0.element) }
        if !hasInitialsStyle { return toks.map { $0.contains(" ") ? $0 : $0 }.joined(separator: "\n") }
        var lines: [String] = []
        var i = 0
        while i < toks.count {
            if i + 1 < toks.count, looksGiven(toks[i + 1]) { lines.append("\(toks[i]), \(toks[i + 1])"); i += 2 }
            else { lines.append(toks[i]); i += 1 }
        }
        return lines.joined(separator: "\n")
    }

    private static func looksGiven(_ s: String) -> Bool {
        // "G. S.", "G.S.", "Gary S.", "J.-P.", "Jean-Paul"
        rx(#"^([A-Z][A-Za-zÀ-ſ'\-]*\.?\s*[-]?\s*)+$"#, s) != nil && s.count <= 40
            && (s.contains(".") || !s.contains(" "))
    }
}
