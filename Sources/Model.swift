import Foundation
import SwiftUI
import ServiceManagement

struct LogEntry: Codable, Identifiable {
    enum Status: String, Codable { case renamed, skipped, undone, pending, kunye }
    var id = UUID()
    var date = Date()
    var status: Status
    var oldPath: String
    var newPath: String?
    var note: String
    var apa: String?        // künye anahtarı (geri alınca listeden silinir); eski kayıtlarda künye metni
    var apaFile: String?
}

/// Kaynakça sekmesindeki bir kaynak satırı
struct RefItem: Identifiable {
    enum Status { case waiting, working, done, pageOnly, notFound, failed }
    let id = UUID()
    var text: String
    var title = ""
    var status: Status = .waiting
    var note = ""
    var page: URL?
    var opened = false
}

/// "Bilgileri gir…" penceresindeki alanlar
struct ManualForm {
    var path = ""
    var authors = ""
    var year = ""
    var type = "journal-article"
    var title = ""
    var container = ""
    var volume = ""
    var issue = ""
    var pages = ""
    var doi = ""
    var publisher = ""
    var ready = ""
    var error = ""
}

struct State: Codable {
    var folders: [String] = []
    var watching = true
    var processExisting = true
    var openAlexKey: String?
    var onlineLookup: Bool?
    var guessMode: Bool?
    var writeApa: Bool?
    var engineVersion: Int?
    var refFolder: String?             // kaynakça PDF'lerinin indirileceği klasör
    var kunyeDone: [String: Double]?   // künyesi işlenmiş, adı zaten doğru dosyalar
    var namedFiles: [String: Double]?  // Biblio'nun kendi adlandırdığı dosyalar (şablondan bağımsız tekrar işlenmesin)
    var language: String?              // "en" (varsayılan) ya da "tr"
    var namePreset: String?            // hazır şablon kimliği ya da "custom"
    var nameTemplate: String?          // özel şablon
    var titleMax: Int?
    var maxAuthors: Int?
    var andWord: String?
    var etAl: String?
    var keepAccents: Bool?
    var citeStyle: String?             // apa, harvard, mla, chicago, ieee
    var refFileName: String?           // künye listesi dosya adı (uzantısız)
    var skipped: [String: Double] = [:]   // yol -> degisiklik zamani (tekrar denememek icin)
    var log: [LogEntry] = []
}

final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    init?(path: String, onChange: @escaping () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler(handler: onChange)
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }
    func stop() { source?.cancel(); source = nil }
}

@MainActor
final class Model: ObservableObject {
    static let shared = Model()

    @Published var state = State() { didSet { applySettings(); save() } }
    @Published var busy = 0
    @Published var targeted = false
    @Published var launchAtLogin = false

    private let processor = Processor()
    private var watchers: [String: FolderWatcher] = [:]
    private var inFlight = Set<String>()
    private var timer: Timer?
    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Biblio")
        let old = base.appendingPathComponent("Kunye")   // eski sürümün klasörü: ayarlar ve geçmiş bir kez taşınır
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    init() {
        if let d = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(State.self, from: d) { state = s }
        if state.engineVersion != 4 { state.skipped = [:]; state.kunyeDone = [:]; state.engineVersion = 4 }   // motor iyileşti: eski "atlandı" kayıtları geçersiz
        applySettings()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        rebuildWatchers()
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanAll(); self?.retryDue() }
        }
        scanAll()
        regenerateRefFiles()   // eski künye listeleri de yeni biçimle (eksikler kırmızı) yenilenir
    }

    func applySettings() {
        Engine.openAlexKey = state.openAlexKey
        Engine.onlineEnabled = state.onlineLookup ?? true
        Engine.guessEnabled = state.guessMode ?? false
        Engine.naming = namingPrefs
        Engine.citeStyle = citeStyle
        Loc.lang = state.language ?? "en"
    }

    /// Arayüz metni: dil ayarını okuduğu için dil değişince görünümler yenilenir.
    func t(_ key: String, _ args: CVarArg...) -> String { _ = state.language; return Loc.tv(key, args) }

    var namingPrefs: NamingPrefs {
        var p = NamingPrefs()
        let preset = state.namePreset ?? "author-year"
        p.template = preset == "custom" ? (state.nameTemplate ?? Namer.defaultTemplate) : (Namer.presets.first { $0.id == preset }?.template ?? Namer.defaultTemplate)
        p.titleMax = state.titleMax ?? 60
        p.maxAuthors = state.maxAuthors ?? 2
        p.andWord = state.andWord ?? "&"
        p.etAl = state.etAl ?? "et al"
        p.keepAccents = state.keepAccents ?? false
        return p
    }

    var citeStyle: CiteStyle { CiteStyle(rawValue: state.citeStyle ?? "apa") ?? .apa }

    private static let sampleRef = Ref(
        authors: [Person(family: "Kahn", given: "Matthew E."), Person(family: "Mansur", given: "Erin T.")], year: 2013,
        title: "Do local energy prices and regulation affect the geographic concentration of employment?",
        container: "Journal of Public Economics", volume: "101", pages: "105-114", doi: "10.1016/j.jpubeco.2013.03.002", type: "journal-article")

    /// Ayarlardaki şablonun örnek bir makaledeki görünümü
    var namePreview: String {
        let f = NameFields(authors: ["Kahn", "Mansur", "Smith"], year: 2013, title: Model.sampleRef.title, journal: Model.sampleRef.container, doi: Model.sampleRef.doi)
        return Namer.render(f, prefs: namingPrefs) + ".pdf"
    }

    var citePreview: AttributedString {
        let s = Cite.format(Model.sampleRef, style: citeStyle)
        return (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }

    private var pendingUntil: [String: Date] = [:] { didSet { pendingCount = pendingUntil.count } }   // ağ/limit yüzünden bekleyenler: 5 dk sonra tekrar
    @Published var pendingCount = 0
    @Published var tab = 0
    @Published var refItems: [RefItem] = []
    @Published var refBusy = false
    @Published var cachedSkipCount = 0
    private var cachedByFolder: [String: Int] = [:]
    @Published var pendingNote = ""
    @Published var manual: ManualForm? = nil      // nil: elle giriş penceresi kapalı

    private func save() {
        if let d = try? JSONEncoder().encode(state) { try? d.write(to: fileURL, options: .atomic) }
    }

    // MARK: Klasorler

    func addFolder(_ url: URL) {
        let p = url.path
        guard !state.folders.contains(p) else { return }
        state.folders.append(p)
        for k in state.skipped.keys where (k as NSString).deletingLastPathComponent == p { state.skipped[k] = nil }   // yeni eklenen klasörde her şeyi yeniden dene
        rebuildWatchers()
        if state.processExisting { scan(folder: p) }
    }

    func removeFolder(_ p: String) {
        state.folders.removeAll { $0 == p }
        rebuildWatchers()
    }

    func rebuildWatchers() {
        watchers.values.forEach { $0.stop() }
        watchers = [:]
        guard state.watching else { return }
        for p in state.folders {
            if let w = FolderWatcher(path: p, onChange: { [weak self] in
                Task { @MainActor in self?.scan(folder: p) }
            }) { watchers[p] = w }
        }
    }

    /// Süresi dolan bekleyen dosyaları (bırakılmış olanlar dahil) yeniden dener.
    private func retryDue() {
        let due = pendingUntil.filter { $0.value <= Date() }.keys.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        for u in due { pendingUntil[u.path] = nil }
        if !due.isEmpty { run(due, force: true) }
    }

    /// Daha önce çözülemeyip atlanan dosyaları yeniden dener.
    func retrySkipped() {
        let folders = Set(state.folders)
        state.kunyeDone = state.kunyeDone?.filter { !folders.contains(($0.key as NSString).deletingLastPathComponent) }
        for k in state.skipped.keys where folders.contains((k as NSString).deletingLastPathComponent) { state.skipped[k] = nil }
        scanAll()
    }

    /// "Şimdi dene": bekleyenleri ve OpenAlex bekleme süresini sıfırlar.
    func retryPending() {
        Engine.openAlexCooldownUntil = .distantPast
        let urls = pendingUntil.keys.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        pendingUntil = [:]
        if !urls.isEmpty { run(urls, force: true) }
        scanAll()
    }

    // MARK: Kaynakça: listedeki eserleri bul, açık erişimlileri indir, diğerlerinin sayfasını aç

    var refFolderURL: URL { URL(fileURLWithPath: state.refFolder ?? (NSHomeDirectory() + "/Downloads/" + (state.language == "tr" ? "Kaynakça" : "References"))) }
    var refPagesWaiting: Int { refItems.filter { $0.page != nil && !$0.opened }.count }

    func chooseRefFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { state.refFolder = u.path }
    }

    func loadRefFile(_ url: URL) {
        let e = Biblio.entries(from: url)
        if e.isEmpty {
            refItems = [RefItem(text: t("%@: no reference lines found (each line needs a year)", url.lastPathComponent), status: .failed)]
            return
        }
        refItems = e.map { RefItem(text: $0) }
        refBusy = true
        let idx = Array(refItems.indices)
        Task {
            await withTaskGroup(of: Void.self) { group in
                var it = idx.makeIterator()
                for _ in 0..<3 { if let i = it.next() { group.addTask { await self.processRef(i) } } }
                while await group.next() != nil { if let i = it.next() { group.addTask { await self.processRef(i) } } }
            }
            refBusy = false
        }
    }

    private func processRef(_ i: Int) async {
        refItems[i].status = .working
        do {
            guard let r = try await Biblio.resolve(refItems[i].text) else {
                refItems[i].status = .notFound; refItems[i].note = t("No matching record found in Crossref"); return
            }
            refItems[i].title = r.title
            let short = Engine.fold(r.title).split(separator: " ").prefix(4).joined(separator: "-")
            var got: [URL] = [], published = false, notes: [String] = []
            var hashes = Set<String>()
            for v in r.versions {
                guard let u = v.pdf else { continue }
                if let f = await Biblio.downloadPDF(u, into: refFolderURL, stem: "ref-\(short)-\(v.isPublished ? "article" : "wp")") {
                    let fp = Biblio.fingerprint(f)
                    if hashes.contains(fp) { try? FileManager.default.removeItem(at: f); if v.isPublished { published = true }; continue }   // aynı dosya zaten indirildi
                    hashes.insert(fp)
                    got.append(f); notes.append(t("%@ downloaded", t(v.label))); if v.isPublished { published = true }
                }
            }
            if !got.isEmpty { run(got, force: true) }   // indirilenler Biblio ile adlandırılır, künyeleri eklenir
            refItems[i].page = published ? nil : r.landing
            var note = notes.joined(separator: ", ")
            if refItems[i].page != nil { note += (note.isEmpty ? "" : "; ") + t("no open PDF for the article: open the page and download it with your subscription") }
            if r.openAlexDown { note += " " + t("(OpenAlex unreachable: working-paper versions were not searched)") }
            refItems[i].note = note
            refItems[i].status = !got.isEmpty ? .done : (refItems[i].page != nil ? .pageOnly : .notFound)
            if got.isEmpty && refItems[i].page == nil { refItems[i].note = t("no downloadable version or page found") }
        } catch {
            refItems[i].status = .failed
            refItems[i].note = Engine.lastIssue.isEmpty ? t("network/limit problem") : Engine.lastIssue
        }
    }

    func openPage(_ id: UUID) {
        guard let i = refItems.firstIndex(where: { $0.id == id }), let u = refItems[i].page else { return }
        NSWorkspace.shared.open(u); refItems[i].opened = true
    }

    func openNextPages(_ n: Int = 5) {
        var c = 0
        for i in refItems.indices where refItems[i].page != nil && !refItems[i].opened && c < n {
            NSWorkspace.shared.open(refItems[i].page!); refItems[i].opened = true; c += 1
        }
    }

    func scanAll() {
        guard state.watching else { return }
        state.folders.forEach { scan(folder: $0) }
    }

    private func pdfs(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return items.filter { $0.pathExtension.lowercased() == "pdf" && !$0.lastPathComponent.hasPrefix("~$") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func mtime(_ u: URL) -> Double {
        ((try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
    }

    private func size(_ u: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? Int ?? -1
    }

    private var needsRescan = false

    func scan(folder: String) {
        // İşlem sürerken (kendi yeniden adlandırmalarımız klasör olayı tetikler) tarama yapma; bitince bir kez taranır
        if busy > 0 { needsRescan = true; return }
        var cached = 0
        let wantKunye = (state.writeApa ?? true) && Engine.onlineEnabled
        let files = pdfs(in: URL(fileURLWithPath: folder)).filter { f in
            if let t = pendingUntil[f.path], t > Date() { return false }
            if state.namedFiles?[f.path] == mtime(f) { return false }   // Biblio'nun kendi adlandırdığı dosya
            if Engine.alreadyNamed(f.deletingPathExtension().lastPathComponent) {
                return wantKunye && state.kunyeDone?[f.path] != mtime(f)    // adı doğru olanlar: künye bir kez üretilir
            }
            if state.skipped[f.path] == mtime(f) { cached += 1; return false }
            return true
        }
        cachedByFolder[folder] = cached
        cachedSkipCount = cachedByFolder.values.reduce(0, +)
        if !files.isEmpty { run(files, force: false) }
    }

    // MARK: Islem

    func handleDrop(_ urls: [URL]) {
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue { files += pdfs(in: u) } else if u.pathExtension.lowercased() == "pdf" { files.append(u) }
        }
        if files.isEmpty { log(LogEntry(status: .skipped, oldPath: urls.first?.path ?? "", newPath: nil, note: t("no PDF found in the dropped item"))) }
        else { run(files, force: true) }
    }

    private func run(_ files: [URL], force: Bool) {
        let todo = files.filter { inFlight.insert($0.path).inserted }
        guard !todo.isEmpty else { return }
        busy += todo.count
        Task {
            // 4 dosya aynı anda: 200 dosyalık bir parti dakikalar içinde biter
            await withTaskGroup(of: Void.self) { group in
                var it = todo.makeIterator()
                for _ in 0..<4 { if let f = it.next() { group.addTask { await self.handle(f, force: force) } } }
                while await group.next() != nil {
                    if let f = it.next() { group.addTask { await self.handle(f, force: force) } }
                }
            }
        }
    }

    private func handle(_ f: URL, force: Bool) async {
        defer {
            inFlight.remove(f.path); busy -= 1
            if busy == 0 && needsRescan { needsRescan = false; scanAll() }
        }
        if !force {
            let s1 = size(f); let t = mtime(f)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if size(f) != s1 || Date().timeIntervalSince1970 - t < 2 { return }   // indirme sürüyor
        }
        finish(await processor.process(f))
    }

    private func finish(_ out: Outcome) {
        switch out {
        case .renamed(let a, let b, let how, let entry):
            pendingUntil[a.path] = nil
            state.log.removeAll { ($0.status == .pending || $0.status == .skipped) && $0.oldPath == a.path }
            var nf = state.namedFiles ?? [:]; nf[b.path] = mtime(b); state.namedFiles = nf
            var e = LogEntry(status: .renamed, oldPath: a.path, newPath: b.path, note: how)
            if state.writeApa ?? true { e.apa = entry.key; e.apaFile = appendEntry(entry, folder: b.deletingLastPathComponent()) }
            log(e)
        case .kunye(let u, let entry):
            pendingUntil[u.path] = nil
            state.log.removeAll { ($0.status == .pending || $0.status == .skipped) && $0.oldPath == u.path }
            var kunyeFile: String? = nil
            if state.writeApa ?? true { kunyeFile = appendEntry(entry, folder: u.deletingLastPathComponent()) }
            var kd = state.kunyeDone ?? [:]; kd[u.path] = mtime(u); state.kunyeDone = kd
            var nf = state.namedFiles ?? [:]; nf[u.path] = mtime(u); state.namedFiles = nf
            var e = LogEntry(status: .kunye, oldPath: u.path, newPath: nil, note: kunyeFile == nil ? "reference was already in the reference list" : "reference added to the reference list")
            e.apa = entry.key; e.apaFile = kunyeFile
            log(e)
        case .flagged(let a, let b, let why):
            pendingUntil[a.path] = nil
            state.log.removeAll { ($0.status == .pending || $0.status == .skipped) && ($0.oldPath == a.path || $0.oldPath == b.path) }
            state.skipped[b.path] = mtime(b)
            log(LogEntry(status: .skipped, oldPath: b.path, newPath: nil, note: t("%@. File renamed to “%@” so it appears at the top of the folder.", t(why), b.lastPathComponent)))
        case .skipped(let u, let why):
            if Engine.alreadyNamed(u.deletingPathExtension().lastPathComponent) {
                var kd = state.kunyeDone ?? [:]; kd[u.path] = mtime(u); state.kunyeDone = kd
            } else { state.skipped[u.path] = mtime(u) }
            log(LogEntry(status: .skipped, oldPath: u.path, newPath: nil, note: why))
        case .pending(let u, let why):
            pendingUntil[u.path] = Date().addingTimeInterval(300)   // ağ yok / limit doldu: 5 dk sonra tekrar
            pendingNote = why
            if !(state.log.first.map { $0.status == .pending && $0.oldPath == u.path } ?? false) {
                log(LogEntry(status: .pending, oldPath: u.path, newPath: nil, note: t("waiting: %@", why)))
            }
        }
    }

    private func log(_ e: LogEntry) {
        state.log.insert(e, at: 0)
        if state.log.count > 300 { state.log.removeLast(state.log.count - 300) }
    }

    // MARK: Künye listesi (klasör başına .docx)
    // Klasördeki künyeler gizli bir yardımcı dosyada (.<ad>.json) tam yayın bilgisiyle tutulur; .docx, seçili stille her seferinde
    // alfabetik sırayla yeniden yazılır. Böylece stil değişince liste de yeni stile geçer.

    /// Listenin dosya adı. Klasörde Biblio'nun yazmadığı (yan dosyası olmayan) bir References.docx varsa onun üzerine yazılmaz: "References (Biblio)" kullanılır.
    private func refBase(_ folder: URL) -> String {
        let fm = FileManager.default
        var name: String
        if let c = state.refFileName?.trimmingCharacters(in: .whitespaces), !c.isEmpty { name = c }
        else if fm.fileExists(atPath: folder.appendingPathComponent(".Künyeler.json").path) { name = "Künyeler" }   // eski sürümlerden devam
        else { name = state.language == "tr" ? "Künyeler" : "References" }
        let suffix = " (Biblio)"
        if fm.fileExists(atPath: folder.appendingPathComponent("." + name + ".json").path) { return name }
        if fm.fileExists(atPath: folder.appendingPathComponent("." + name + suffix + ".json").path) { return name + suffix }
        if fm.fileExists(atPath: folder.appendingPathComponent(name + ".docx").path) { return name + suffix }
        return name
    }

    /// Klasörün künye listesini boşaltır: .docx Çöp Sepeti'ne taşınır, yan dosya silinir. Sonraki künyeler yeni bir listeye yazılır.
    func resetRefList(folder: String) {
        let url = URL(fileURLWithPath: folder)
        let base = refBase(url)
        let side = url.appendingPathComponent("." + base + ".json")
        guard FileManager.default.fileExists(atPath: side.path) else { return }   // Biblio'nun yazmadığı dosyaya dokunma
        let docx = url.appendingPathComponent(base + ".docx")
        if FileManager.default.fileExists(atPath: docx.path) { try? FileManager.default.trashItem(at: docx, resultingItemURL: nil) }
        try? FileManager.default.removeItem(at: side)
        for i in state.log.indices where state.log[i].apaFile == docx.path { state.log[i].apaFile = nil; state.log[i].apa = nil }
    }

    func hasRefList(folder: String) -> Bool {
        let url = URL(fileURLWithPath: folder)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("." + refBase(url) + ".json").path)
    }

    private func loadEntries(_ folder: URL) -> [RefEntry] {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("." + refBase(folder) + ".json")) else { return [] }
        if let e = try? JSONDecoder().decode([RefEntry].self, from: d) { return e }
        return ((try? JSONDecoder().decode([String].self, from: d)) ?? []).map { RefEntry(text: $0) }   // eski biçim: hazır metin satırları
    }

    private func saveEntries(_ entries: [RefEntry], folder: URL) -> String? {
        let base = refBase(folder)
        let docx = folder.appendingPathComponent(base + ".docx")
        let side = folder.appendingPathComponent("." + base + ".json")
        let rendered = entries.map { (text: $0.render(citeStyle), flagged: $0.needsCheck) }
            .sorted { Engine.fold($0.text.replacingOccurrences(of: "*", with: "")).lowercased() < Engine.fold($1.text.replacingOccurrences(of: "*", with: "")).lowercased() }
        do {
            if entries.isEmpty {
                try? FileManager.default.removeItem(at: docx); try? FileManager.default.removeItem(at: side); return nil
            }
            try JSONEncoder().encode(entries).write(to: side, options: .atomic)
            try Docx.build(entries: rendered).write(to: docx, options: .atomic)
            return docx.path
        } catch { return nil }
    }

    /// Künyeyi klasördeki listeye ekler. Eklediyse .docx yolunu döndürür (zaten varsa nil).
    private func appendEntry(_ entry: RefEntry, folder: URL) -> String? {
        var entries = loadEntries(folder)
        if entries.contains(where: { $0.key == entry.key }) { return nil }
        entries.append(entry)
        return saveEntries(entries, folder: folder)
    }

    private func removeEntry(_ e: LogEntry) {
        guard let path = e.apaFile, let key = e.apa else { return }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        var entries = loadEntries(folder)
        entries.removeAll { $0.key == key || $0.text == key }
        _ = saveEntries(entries, folder: folder)
    }

    /// Stil ya da dosya adı değişince bilinen klasörlerdeki listeleri yeniden yazar.
    func regenerateRefFiles() {
        var folders = Set(state.folders)
        for e in state.log { if let f = e.apaFile { folders.insert(URL(fileURLWithPath: f).deletingLastPathComponent().path) } }
        for f in folders {
            let url = URL(fileURLWithPath: f)
            let entries = loadEntries(url)
            if !entries.isEmpty { _ = saveEntries(entries, folder: url) }
        }
    }

    func undo(_ e: LogEntry) {
        if e.status == .kunye {
            removeEntry(e)
            if let i = state.log.firstIndex(where: { $0.id == e.id }) { state.log[i].status = .undone }
            return
        }
        guard e.status == .renamed, let n = e.newPath else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: n), !fm.fileExists(atPath: e.oldPath) else { return }
        do {
            try fm.moveItem(atPath: n, toPath: e.oldPath)
            state.namedFiles?[n] = nil
            removeEntry(e)
            if let i = state.log.firstIndex(where: { $0.id == e.id }) { state.log[i].status = .undone }
            state.skipped[e.oldPath] = mtime(URL(fileURLWithPath: e.oldPath))   // hemen tekrar adlandirma
        } catch {}
    }

    func undoLast() {
        if let e = state.log.first(where: { $0.status == .renamed }) { undo(e) }
    }

    // MARK: Elle giriş: otomatik çözülemeyen dosya için bilgileri kullanıcı yazar

    func openManual(_ path: String) {
        manual = ManualForm(path: path)
        // Sayfadan tahmin edilebilenleri (DOI, yıl, yazar satırı) önceden doldur; kullanıcı düzeltir.
        Task.detached {
            let d = Engine.read(URL(fileURLWithPath: path))
            let first = d.pages.first ?? ""
            let doi = Engine.matches(#"10\.\d{4,9}/[^\s"<>]+"#, in: d.text).first?.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}")) ?? ""
            let year = Engine.guessYear(first).map(String.init) ?? ""
            let authors = Engine.localGuess(first)?.0.joined(separator: "\n") ?? ""
            await MainActor.run {
                guard var f = self.manual, f.path == path else { return }
                if f.doi.isEmpty { f.doi = doi }
                if f.year.isEmpty { f.year = year }
                if f.authors.isEmpty { f.authors = authors }
                self.manual = f
            }
        }
    }

    static func parsePeople(_ s: String) -> [Person] {
        s.split(whereSeparator: { $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { line in
                if let c = line.firstIndex(of: ",") {
                    return Person(family: String(line[..<c]).trimmingCharacters(in: .whitespaces),
                                  given: String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces))
                }
                return Engine.splitName(line)   // "Matthew E. Kahn"
            }
    }

    /// Hazır künye kutusundaki metinden alanları doldurur. overwrite=false: yalnızca boş alanları.
    func fillFromReference(overwrite: Bool) {
        guard var f = manual, let p = RefParse.parse(f.ready) else {
            if manual != nil { manual?.error = t("Could not read that reference. Fill the fields by hand.") }
            return
        }
        func put(_ cur: inout String, _ new: String) { if !new.isEmpty, overwrite || cur.trimmingCharacters(in: .whitespaces).isEmpty { cur = new } }
        put(&f.authors, p.authors); put(&f.year, p.year); put(&f.title, p.title); put(&f.container, p.container)
        put(&f.volume, p.volume); put(&f.issue, p.issue); put(&f.pages, p.pages); put(&f.doi, p.doi); put(&f.publisher, p.publisher)
        if !p.type.isEmpty { f.type = p.type }
        f.error = ""
        manual = f
    }

    func submitManual() {
        if let f = manual, !f.ready.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           f.authors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fillFromReference(overwrite: false) }
        guard var f = manual else { return }
        let people = Model.parsePeople(f.authors)
        if people.isEmpty { f.error = t("Enter at least one author"); manual = f; return }
        let ytxt = f.year.trimmingCharacters(in: .whitespaces)
        var year: Int? = nil
        if !ytxt.isEmpty {
            guard let y = Int(ytxt), (1000...(Engine.currentYear + 1)).contains(y) else {
                f.error = t("The year must be four digits (or leave it empty)"); manual = f; return
            }
            year = y
        }
        func v(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let ref = Ref(authors: people, editors: [], year: year, title: v(f.title), container: v(f.container), volume: v(f.volume),
                      issue: v(f.issue), pages: v(f.pages), doi: v(f.doi), publisher: v(f.publisher), type: f.type)
        let ready = v(f.ready)
        let entry: RefEntry
        if !ready.isEmpty { entry = RefEntry(text: ready) }
        else if !ref.title.isEmpty { entry = RefEntry(ref: ref) }
        else { entry = RefEntry(text: Cite.minimal(authors: people.map { $0.family }, year: year), key: "m:" + Engine.squash(people.map { $0.family }.joined()) + "|\(year ?? 0)") }
        let url = URL(fileURLWithPath: f.path)
        manual = nil
        busy += 1
        Task {
            let out = await processor.renameManual(url, authors: people.map { $0.family }, year: year, ref: ref, entry: entry)
            finish(out)
            busy -= 1
        }
    }

    // MARK: Geçmiş: yalnızca listede görünenleri siler; dosyalara ve künye listesine dokunmaz

    func clearLog() { state.log = [] }

    func removeLogEntry(_ id: UUID) { state.log.removeAll { $0.id == id } }

    /// Kaynakça listesi işlenirken satırlar sıra numarasıyla güncellendiği için o sırada silinmez.
    func clearRefItems() { if !refBusy { refItems = [] } }

    func removeRefItem(_ id: UUID) { if !refBusy { refItems.removeAll { $0.id == id } } }

    func clearAllHistory() { clearLog(); clearRefItems() }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
