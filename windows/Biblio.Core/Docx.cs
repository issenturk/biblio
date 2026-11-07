using System.IO.Compression;
using System.Text;

namespace Biblio.Core;

/// <summary>Minimal .docx üretici: hanging indent, çift aralık, Times New Roman 12, A4. *...* italik; flagged: kalın kırmızı.</summary>
public static class Docx
{
    static string Esc(string s) => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");

    static string Runs(string line, bool flagged)
    {
        var sb = new StringBuilder();
        var parts = line.Split('*');
        for (int i = 0; i < parts.Length; i++)
        {
            if (parts[i].Length == 0) continue;
            var rpr = "<w:rPr>" + (flagged ? "<w:b/>" : "") + (i % 2 == 1 ? "<w:i/>" : "") + (flagged ? "<w:color w:val=\"C00000\"/>" : "") + "</w:rPr>";
            sb.Append($"<w:r>{rpr}<w:t xml:space=\"preserve\">{Esc(parts[i])}</w:t></w:r>");
        }
        return sb.ToString();
    }

    public static byte[] Build(IEnumerable<(string Text, bool Flagged)> entries)
    {
        const string ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"";
        const string head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>";
        var paras = string.Concat(entries.Select(e =>
            "<w:p><w:pPr><w:spacing w:line=\"480\" w:lineRule=\"auto\" w:after=\"0\"/><w:ind w:left=\"720\" w:hanging=\"720\"/></w:pPr>" + Runs(e.Text, e.Flagged) + "</w:p>"));
        var document = head + $"<w:document {ns}><w:body>{paras}<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/>"
            + "<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>";
        var styles = head + $"<w:styles {ns}><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Times New Roman\" w:hAnsi=\"Times New Roman\" w:cs=\"Times New Roman\"/>"
            + "<w:sz w:val=\"24\"/><w:szCs w:val=\"24\"/><w:lang w:val=\"en-US\"/></w:rPr></w:rPrDefault></w:docDefaults></w:styles>";
        var types = head + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/></Types>";
        var rels = head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>";
        var docRels = head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>";

        using var ms = new MemoryStream();
        using (var zip = new ZipArchive(ms, ZipArchiveMode.Create, true))
        {
            void Add(string name, string content)
            {
                var e = zip.CreateEntry(name, CompressionLevel.Optimal);
                using var w = new StreamWriter(e.Open(), new UTF8Encoding(false));
                w.Write(content);
            }
            Add("[Content_Types].xml", types);
            Add("_rels/.rels", rels);
            Add("word/document.xml", document);
            Add("word/styles.xml", styles);
            Add("word/_rels/document.xml.rels", docRels);
        }
        return ms.ToArray();
    }
}
