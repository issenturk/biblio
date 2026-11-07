import Foundation

// Kullanım: biblio-cli [--dry-run] [--evaluate] [--apa] [--guess] [--template "{Author} - {Year}"] [--title-max 60]
//                     [--authors 2] [--and "&"] [--accents] [--style apa|harvard|mla|chicago|ieee] [--lang en|tr] DOSYA_veya_KLASOR...
var args = Array(CommandLine.arguments.dropFirst())
func take(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
if let t = take("--template") { Engine.naming.template = t }
if let v = take("--title-max").flatMap(Int.init) { Engine.naming.titleMax = v }
if let v = take("--authors").flatMap(Int.init) { Engine.naming.maxAuthors = v }
if let v = take("--and") { Engine.naming.andWord = v }
if let v = take("--style").flatMap(CiteStyle.init(rawValue:)) { Engine.citeStyle = v }
if let v = take("--lang") { Loc.lang = v }
let dry = args.contains("--dry-run")
let evalMode = args.contains("--evaluate")
if args.contains("--accents") { Engine.naming.keepAccents = true }
if evalMode { Engine.useFilename = false }
if args.contains("--guess") { Engine.guessEnabled = true }
let paths = args.filter { !$0.hasPrefix("--") }
let proc = Processor()
var files: [URL] = []
for p in paths {
    let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
    if isDir.boolValue {
        let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        files += items.filter { $0.pathExtension.lowercased() == "pdf" && !$0.lastPathComponent.hasPrefix("~$") }.sorted { $0.path < $1.path }
    } else { files.append(u) }
}
for f in files {
    switch await proc.process(f, dryRun: dry, evaluate: evalMode) {
    case .renamed(let a, let b, let how, let entry):
        print("\(a.lastPathComponent)\n   -> \(b.lastPathComponent)  [\(how)]")
        if args.contains("--apa") { print("   REF: \(entry.render(Engine.citeStyle))") }
    case .flagged(let a, let b, let why): print("!! \(a.lastPathComponent) -> \(b.lastPathComponent): \(why)")
    case .skipped(let u, let why): print("-- \(u.lastPathComponent): \(why)")
    case .pending(let u, let why): print("?? \(u.lastPathComponent): \(why)")
    case .kunye(let u, let entry): print("REF \(u.lastPathComponent)\n   \(entry.render(Engine.citeStyle))")
    }
}
