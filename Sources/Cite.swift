import Foundation

/// Künye (kaynakça) stilleri. İtalik yazılacak kısımlar *...* ile işaretlenir; Docx.swift bunları italik yazar.
enum CiteStyle: String, CaseIterable, Identifiable {
    case apa, harvard, mla, chicago, ieee
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apa: return "APA 7"
        case .harvard: return "Harvard"
        case .mla: return "MLA 9"
        case .chicago: return "Chicago (author-date)"
        case .ieee: return "IEEE"
        }
    }
}

/// Saklanan bir künye: tam yayın bilgisi varsa stil değişince yeniden biçimlenir; yoksa sabit metin.
struct RefEntry: Codable {
    var key: String
    var ref: Ref?
    var text: String?

    init(ref: Ref) {
        self.ref = ref
        let doi = ref.doi.lowercased()
        key = doi.isEmpty ? "t:" + Engine.squash(ref.title) + "|\(ref.year ?? 0)" : "d:" + doi
    }

    init(text: String, key: String? = nil) {
        self.text = text
        self.key = key ?? "x:" + Engine.squash(text)
    }

    /// Eksik/emin olunmayan künye: docx'te kırmızı ve kalın yazılır.
    var needsCheck: Bool {
        if let r = ref {
            return r.year == nil || r.title.trimmingCharacters(in: .whitespaces).isEmpty || r.authors.isEmpty
                || (r.type == "journal-article" && r.container.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        return key.hasPrefix("m:")   // yalnızca yazar+yıldan üretilen asgari künye
    }

    func render(_ style: CiteStyle) -> String { ref.map { Cite.format($0, style: style) } ?? (text ?? "") }
}

enum Cite {
    // MARK: Ortak yardımcılar

    private static func compactInitials(_ given: String) -> String { Apa.initials(given).replacingOccurrences(of: " ", with: "") }

    private static func bare(_ d: String) -> String {
        d.replacingOccurrences(of: "https://doi.org/", with: "").replacingOccurrences(of: "http://dx.doi.org/", with: "").trimmingCharacters(in: .whitespaces)
    }

    private static func pages(_ p: String) -> String { p.replacingOccurrences(of: "-", with: "–") }

    private static func end(_ s: String) -> String { Apa.ending(s) }

    private static func headline(_ t: String) -> String {
        let c = Apa.clean(t)
        return (c == c.uppercased() && c != c.lowercased()) ? c.capitalized : c
    }

    private static func given(_ p: Person) -> String { Apa.clean(p.given) }
    private static func family(_ p: Person) -> String { Apa.clean(p.family) }

    /// "Soyad, Ad" (ilk yazar) / "Ad Soyad" (diğerleri)
    private static func lastFirst(_ p: Person) -> String { given(p).isEmpty ? family(p) : "\(family(p)), \(given(p))" }
    private static func firstLast(_ p: Person) -> String { given(p).isEmpty ? family(p) : "\(given(p)) \(family(p))" }

    // MARK: Biçimlendirme

    static func format(_ r: Ref, style: CiteStyle) -> String {
        switch style {
        case .apa: return Apa.format(r)
        case .harvard: return harvard(r)
        case .mla: return mla(r)
        case .chicago: return chicago(r)
        case .ieee: return ieee(r)
        }
    }

    private static func isJournal(_ r: Ref) -> Bool { r.type == "journal-article" && !Apa.clean(r.container).isEmpty }
    private static func isChapter(_ r: Ref) -> Bool { (r.type == "book-chapter" || r.type == "chapter") && !Apa.clean(r.container).isEmpty }
    private static func join(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.joined(separator: " ").replacingOccurrences(of: "  ", with: " ") }

    // Harvard (Cite Them Right)
    private static func harvard(_ r: Ref) -> String {
        let people = r.authors.map { p -> String in
            let i = compactInitials(p.given)
            return i.isEmpty ? family(p) : "\(family(p)), \(i)"
        }
        var a = ""
        switch people.count {
        case 0: a = ""
        case 1: a = people[0]
        case 2, 3: a = people.dropLast().joined(separator: ", ") + " and " + people.last!
        default: a = people[0] + " et al."
        }
        let year = "(\(r.year.map(String.init) ?? "no date"))"
        let title = Apa.fixTitle(Apa.clean(r.title))
        let doi = r.doi.isEmpty ? "" : "doi: \(bare(r.doi))"
        if isJournal(r) {
            var src = "*\(Apa.journalCase(r.container))*"
            if !r.volume.isEmpty { src += ", \(r.volume)" + (r.issue.isEmpty ? "" : "(\(r.issue))") }
            if !r.pages.isEmpty { src += ", pp. \(pages(r.pages))" }
            return join([a, year, "‘\(title)’,", src + ".", doi])
        }
        if isChapter(r) {
            let eds = r.editors.map { p -> String in let i = compactInitials(p.given); return i.isEmpty ? family(p) : "\(i) \(family(p))" }
            var s = join([a, year, "‘\(title)’, in"])
            if !eds.isEmpty { s += " " + eds.joined(separator: ", ") + (eds.count == 1 ? " (ed.)" : " (eds.)") }
            s += " *\(Apa.clean(r.container))*."
            if !Apa.clean(r.publisher).isEmpty { s += " \(Apa.clean(r.publisher))" + (r.pages.isEmpty ? "." : ", pp. \(pages(r.pages)).") }
            return join([s, doi])
        }
        return join([a, year, "*\(end(title))*", Apa.clean(r.publisher).isEmpty ? "" : end(Apa.clean(r.publisher)), doi])
    }

    // MLA 9
    private static func mla(_ r: Ref) -> String {
        var a = ""
        switch r.authors.count {
        case 0: a = ""
        case 1: a = lastFirst(r.authors[0])
        case 2: a = lastFirst(r.authors[0]) + ", and " + firstLast(r.authors[1])
        default: a = lastFirst(r.authors[0]) + ", et al"
        }
        let title = headline(r.title)
        let doi = r.doi.isEmpty ? "" : "https://doi.org/" + bare(r.doi)
        let year = r.year.map(String.init) ?? "n.d."
        let head = a.isEmpty ? "" : end(a)
        if isJournal(r) {
            var src = "*\(Apa.journalCase(r.container))*"
            if !r.volume.isEmpty { src += ", vol. \(r.volume)" }
            if !r.issue.isEmpty { src += ", no. \(r.issue)" }
            src += ", \(year)"
            if !r.pages.isEmpty { src += ", pp. \(pages(r.pages))" }
            return join([head, "“\(end(title))”", src + ".", doi.isEmpty ? "" : doi + "."])
        }
        if isChapter(r) {
            var src = "*\(Apa.clean(r.container))*"
            if !r.editors.isEmpty { src += ", edited by " + r.editors.map(firstLast).joined(separator: r.editors.count > 2 ? ", " : " and ") }
            if !Apa.clean(r.publisher).isEmpty { src += ", \(Apa.clean(r.publisher))" }
            src += ", \(year)"
            if !r.pages.isEmpty { src += ", pp. \(pages(r.pages))" }
            return join([head, "“\(end(title))”", src + ".", doi.isEmpty ? "" : doi + "."])
        }
        let pub = Apa.clean(r.publisher)
        return join([head, "*\(end(title))*", pub.isEmpty ? "\(year)." : "\(pub), \(year).", doi.isEmpty ? "" : doi + "."])
    }

    // Chicago (author-date)
    private static func chicago(_ r: Ref) -> String {
        let all = r.authors
        var a = ""
        if all.count > 10 {
            a = ([lastFirst(all[0])] + all[1..<7].map(firstLast)).joined(separator: ", ") + ", et al."
        } else if all.count == 1 {
            a = lastFirst(all[0])
        } else if all.count == 2 {
            a = lastFirst(all[0]) + " and " + firstLast(all[1])
        } else if all.count > 2 {
            a = ([lastFirst(all[0])] + all.dropFirst().dropLast().map(firstLast)).joined(separator: ", ") + ", and " + firstLast(all.last!)
        }
        let year = r.year.map(String.init) ?? "n.d."
        let title = headline(r.title)
        let doi = r.doi.isEmpty ? "" : "https://doi.org/" + bare(r.doi) + "."
        let head = a.isEmpty ? "" : end(a)
        if isJournal(r) {
            var src = "*\(Apa.journalCase(r.container))*"
            if !r.volume.isEmpty { src += " \(r.volume)" }
            if !r.issue.isEmpty { src += " (\(r.issue))" }
            if !r.pages.isEmpty { src += ": \(pages(r.pages))" }
            return join([head, "\(year).", "“\(end(title))”", src + ".", doi])
        }
        if isChapter(r) {
            var src = "In *\(Apa.clean(r.container))*"
            if !r.editors.isEmpty { src += ", edited by " + r.editors.map(firstLast).joined(separator: r.editors.count > 2 ? ", " : " and ") }
            if !r.pages.isEmpty { src += ", \(pages(r.pages))" }
            return join([head, "\(year).", "“\(end(title))”", src + ".", Apa.clean(r.publisher).isEmpty ? "" : end(Apa.clean(r.publisher)), doi])
        }
        return join([head, "\(year).", "*\(end(title))*", Apa.clean(r.publisher).isEmpty ? "" : end(Apa.clean(r.publisher)), doi])
    }

    // IEEE (numaralandırma eklenmez)
    private static func ieee(_ r: Ref) -> String {
        let names = r.authors.map { p -> String in
            let i = Apa.initials(p.given)
            return i.isEmpty ? family(p) : "\(i) \(family(p))"
        }
        var a = ""
        switch names.count {
        case 0: a = ""
        case 1: a = names[0]
        case 2: a = names[0] + " and " + names[1]
        case 3...6: a = names.dropLast().joined(separator: ", ") + ", and " + names.last!
        default: a = names[0] + " et al."
        }
        let year = r.year.map(String.init) ?? "n.d."
        let title = headline(r.title)
        let doi = r.doi.isEmpty ? "" : "doi: \(bare(r.doi))."
        if isJournal(r) {
            var src = "*\(Apa.journalCase(r.container))*"
            if !r.volume.isEmpty { src += ", vol. \(r.volume)" }
            if !r.issue.isEmpty { src += ", no. \(r.issue)" }
            if !r.pages.isEmpty { src += ", pp. \(pages(r.pages))" }
            src += ", \(year)"
            return join([a.isEmpty ? "" : a + ",", "“\(title),”", src + (doi.isEmpty ? "." : ","), doi])
        }
        if isChapter(r) {
            var src = "in *\(Apa.clean(r.container))*"
            if !r.editors.isEmpty { src += ", " + r.editors.map { p -> String in let i = Apa.initials(p.given); return i.isEmpty ? family(p) : "\(i) \(family(p))" }.joined(separator: ", ") + (r.editors.count == 1 ? ", Ed." : ", Eds.") }
            if !Apa.clean(r.publisher).isEmpty { src += ". \(Apa.clean(r.publisher))" }
            src += ", \(year)"
            if !r.pages.isEmpty { src += ", pp. \(pages(r.pages))" }
            return join([a.isEmpty ? "" : a + ",", "“\(title),”", src + (doi.isEmpty ? "." : ","), doi])
        }
        let pub = Apa.clean(r.publisher)
        return join([a.isEmpty ? "" : a + ",", "*\(title)*.", pub.isEmpty ? "\(year)." : "\(pub), \(year).", doi])
    }

    /// Yalnızca yazar ve yıl biliniyorsa
    static func minimal(authors: [String], year: Int?) -> String {
        let a = authors.count <= 2 ? authors.joined(separator: " & ") : authors[0] + " et al."
        return "\(a) (\(year.map(String.init) ?? "n.d.")). " + Loc.t("[Incomplete reference: title and publication details not found]")
    }
}
