import Foundation

/// Minimal .docx üretici (ek kütüphane yok): APA kaynakça biçimi, yani asılı girinti, çift aralık, Times New Roman 12.
/// Satırlardaki *...* aralıkları italik yazılır.
enum Docx {
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    private static func u16(_ v: Int) -> Data { var x = UInt16(v).littleEndian; return Data(bytes: &x, count: 2) }
    private static func u32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }

    /// Sıkıştırmasız (stored) ZIP; .docx için yeterli.
    private static func zip(_ files: [(String, Data)]) -> Data {
        var out = Data(), central = Data()
        for (name, data) in files {
            let n = Data(name.utf8)
            let crc = crc32(data)
            let size = UInt32(data.count)
            let offset = UInt32(out.count)
            var local = Data()
            local.append(u32(0x04034b50)); local.append(u16(20)); local.append(u16(0x0800)); local.append(u16(0)); local.append(u16(0)); local.append(u16(0x21))
            local.append(u32(crc)); local.append(u32(size)); local.append(u32(size)); local.append(u16(n.count)); local.append(u16(0))
            local.append(n); local.append(data)
            out.append(local)
            var cd = Data()
            cd.append(u32(0x02014b50)); cd.append(u16(20)); cd.append(u16(20)); cd.append(u16(0x0800)); cd.append(u16(0)); cd.append(u16(0)); cd.append(u16(0x21))
            cd.append(u32(crc)); cd.append(u32(size)); cd.append(u32(size)); cd.append(u16(n.count))
            cd.append(u16(0)); cd.append(u16(0)); cd.append(u16(0)); cd.append(u16(0)); cd.append(u32(0)); cd.append(u32(offset)); cd.append(n)
            central.append(cd)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        var end = Data()
        end.append(u32(0x06054b50)); end.append(u16(0)); end.append(u16(0)); end.append(u16(files.count)); end.append(u16(files.count))
        end.append(u32(UInt32(central.count))); end.append(u32(cdOffset)); end.append(u16(0))
        out.append(end)
        return out
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func runs(_ line: String, flagged: Bool = false) -> String {
        var out = ""
        for (i, part) in line.components(separatedBy: "*").enumerated() where !part.isEmpty {
            let rpr = "<w:rPr>" + (flagged ? "<w:b/>" : "") + (i % 2 == 1 ? "<w:i/>" : "") + (flagged ? "<w:color w:val=\"C00000\"/>" : "") + "</w:rPr>"
            out += "<w:r>\(rpr)<w:t xml:space=\"preserve\">\(esc(part))</w:t></w:r>"
        }
        return out
    }

    static func build(entries: [(text: String, flagged: Bool)]) -> Data {
        let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        let paras = entries.map {
            "<w:p><w:pPr><w:spacing w:line=\"480\" w:lineRule=\"auto\" w:after=\"0\"/><w:ind w:left=\"720\" w:hanging=\"720\"/></w:pPr>\(runs($0.text, flagged: $0.flagged))</w:p>"
        }.joined()
        let document = head + "<w:document \(ns)><w:body>\(paras)<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/>"
            + "<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>"
        let styles = head + "<w:styles \(ns)><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Times New Roman\" w:hAnsi=\"Times New Roman\" w:cs=\"Times New Roman\"/>"
            + "<w:sz w:val=\"24\"/><w:szCs w:val=\"24\"/><w:lang w:val=\"en-US\"/></w:rPr></w:rPrDefault></w:docDefaults></w:styles>"
        let types = head + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/></Types>"
        let rels = head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"
        let docRels = head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>"
        return zip([("[Content_Types].xml", Data(types.utf8)), ("_rels/.rels", Data(rels.utf8)),
                    ("word/document.xml", Data(document.utf8)), ("word/styles.xml", Data(styles.utf8)),
                    ("word/_rels/document.xml.rels", Data(docRels.utf8))])
    }
}
