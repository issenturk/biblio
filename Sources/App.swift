import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
}

@main
struct PdfAdiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model.shared

    var body: some Scene {
        Window("Biblio", id: "main") {
            TabView(selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
                ContentView().tabItem { Text(model.t("Rename")) }.tag(0)
                RefView().tabItem { Text(model.t("References")) }.tag(1)
                SettingsView().tabItem { Text(model.t("Settings")) }.tag(2)
            }
            .environmentObject(model)
            .frame(minWidth: 580, minHeight: 720)
        }
    }
}

// MARK: Adlandır sekmesi

struct ContentView: View {
    @State private var resetFolder: String?
    @EnvironmentObject var model: Model
    private var targeted: Bool { model.targeted }

    var body: some View {
        VStack(spacing: 14) {
            dropZone
            if model.pendingCount > 0 { pendingBanner }
            if model.cachedSkipCount > 0 { skippedBanner }
            folders
            logList
        }
        .padding(16)
        .sheet(isPresented: Binding(get: { model.manual != nil }, set: { if !$0 { model.manual = nil } })) {
            ManualSheet().environmentObject(model)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.badge.arrow.up").font(.system(size: 28))
            Text(model.t("Drop PDFs or folders")).font(.headline)
            Text(model.t("Files are renamed like: %@", model.namePreview)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.busy > 0 { ProgressView().controlSize(.small); Text(model.t("%d files processing…", model.busy)).font(.caption) }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.15) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6])).foregroundStyle(targeted ? Color.accentColor : .secondary))
        .dropDestination(for: URL.self, action: { urls, _ in model.handleDrop(urls); return true }, isTargeted: { model.targeted = $0 })
        .onTapGesture { pickFiles() }
    }

    private var skippedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
            Text(model.t("%d files are being skipped because they could not be resolved earlier.", model.cachedSkipCount)).font(.caption)
            Spacer()
            Button(model.t("Retry")) { model.retrySkipped() }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.15)))
    }

    private var pendingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.t("%d files waiting", model.pendingCount)).font(.headline)
                Text(model.t("%@. Will retry automatically.", model.pendingNote)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.t("Retry now")) { model.retryPending() }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private var folders: some View {
        GroupBox(model.t("Watched folders")) {
            VStack(alignment: .leading, spacing: 6) {
                if model.state.folders.isEmpty {
                    Text(model.t("No folders yet. PDFs that land in a folder you add are renamed automatically.")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.state.folders, id: \.self) { p in
                    HStack {
                        Image(systemName: "folder")
                        Text((p as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if model.hasRefList(folder: p) {
                            Button { resetFolder = p } label: { Image(systemName: "arrow.counterclockwise.circle") }
                                .buttonStyle(.borderless)
                                .help(model.t("Start a new reference list for this folder (the current .docx is moved to the Trash)"))
                        }
                        Button { model.removeFolder(p) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button(model.t("Add folder…")) { pickFolder() }
                    Spacer()
                    Toggle(model.t("Rename watched folders automatically"), isOn: Binding(
                        get: { model.state.watching }, set: { model.state.watching = $0; model.rebuildWatchers(); model.scanAll() }))
                        .toggleStyle(.checkbox)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .confirmationDialog(model.t("Start a new reference list for this folder?"), isPresented: Binding(get: { resetFolder != nil }, set: { if !$0 { resetFolder = nil } }), titleVisibility: .visible) {
            Button(model.t("Start new list"), role: .destructive) { if let f = resetFolder { model.resetRefList(folder: f) }; resetFolder = nil }
            Button(model.t("Cancel"), role: .cancel) { resetFolder = nil }
        } message: {
            Text(model.t("The current reference list (.docx) of this folder is moved to the Trash and the next references start a fresh list. PDFs are not touched."))
        }
    }

    private var logList: some View {
        GroupBox {
            VStack(spacing: 6) {
                HStack {
                    Text(model.t("Recent activity")).font(.headline)
                    Spacer()
                    Button(model.t("Clear history")) { model.clearLog() }
                        .disabled(model.state.log.isEmpty)
                    Button(model.t("Undo last")) { model.undoLast() }
                        .disabled(!model.state.log.contains { $0.status == .renamed })
                }
                List(model.state.log.prefix(100)) { e in row(e) }.listStyle(.plain)
            }.padding(4)
        }
    }

    private static let verifiedSources: Set<String> = ["cover", "filename", "doi", "id", "title", "working-paper", "isbn", "manual",
                                                       "kapak", "dosya adı", "kimlik", "baslik", "calisma-kagidi"]

    private func row(_ e: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: e.status == .renamed ? "checkmark.circle.fill" : e.status == .undone ? "arrow.uturn.backward.circle" : e.status == .pending ? "clock" : e.status == .kunye ? "text.book.closed" : "minus.circle")
                .foregroundStyle(e.status == .renamed || e.status == .kunye ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                let old = (e.oldPath as NSString).lastPathComponent
                if let n = e.newPath {
                    Text("\(old)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("→ \((n as NSString).lastPathComponent)").lineLimit(1)
                    Text(Self.verifiedSources.contains(e.note) ? model.t("source: %@", model.t(e.note)) : model.t("source: %@ (guess, please check)", model.t(e.note)))
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(old).lineLimit(1)
                    Text(model.t(e.note)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if e.status == .skipped && e.oldPath.lowercased().hasSuffix(".pdf") && FileManager.default.fileExists(atPath: e.oldPath) {
                Button(model.t("Enter details…")) { model.openManual(e.oldPath) }.buttonStyle(.borderless)
            }
            if e.status == .renamed || (e.status == .kunye && e.apaFile != nil) { Button(model.t("Undo")) { model.undo(e) }.buttonStyle(.borderless) }
            Button { model.removeLogEntry(e.id) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help(model.t("Remove this row from the list. Files and the reference list are not changed."))
        }
    }

    private func pickFiles() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf]; p.allowsMultipleSelection = true; p.canChooseDirectories = true
        if p.runModal() == .OK { model.handleDrop(p.urls) }
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        if p.runModal() == .OK { p.urls.forEach { model.addFolder($0) } }
    }
}

// MARK: Elle giriş penceresi

struct ManualSheet: View {
    @EnvironmentObject var model: Model

    private func b(_ kp: WritableKeyPath<ManualForm, String>) -> Binding<String> {
        Binding(get: { model.manual?[keyPath: kp] ?? "" }, set: { model.manual?[keyPath: kp] = $0 })
    }

    private func field(_ label: String, _ kp: WritableKeyPath<ManualForm, String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", text: b(kp)).textFieldStyle(.roundedBorder)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.t("Enter details manually")).font(.headline)
            Text(((model.manual?.path ?? "") as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)

            Text(model.t("Authors (one per line: Family, Given)")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: b(\.authors)).font(.body).frame(height: 62).border(Color.gray.opacity(0.4))

            HStack(alignment: .bottom, spacing: 10) {
                field(model.t("Year"), \.year).frame(width: 90)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.t("Type")).font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: b(\.type)) {
                        Text(model.t("Journal article")).tag("journal-article")
                        Text(model.t("Book")).tag("book")
                        Text(model.t("Book chapter")).tag("book-chapter")
                        Text(model.t("Report / working paper")).tag("report")
                    }.labelsHidden()
                }
            }
            field(model.t("Title"), \.title)
            field(model.t("Journal / book title"), \.container)
            HStack(spacing: 10) {
                field(model.t("Volume"), \.volume)
                field(model.t("Issue"), \.issue)
                field(model.t("Pages"), \.pages)
            }
            HStack(spacing: 10) {
                field(model.t("DOI"), \.doi)
                field(model.t("Publisher"), \.publisher)
            }

            Text(model.t("Ready-made reference (optional). It is added to the list exactly as written; put italic parts between *stars*. If empty, it is built from the fields above."))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: b(\.ready)).font(.body).frame(height: 62).border(Color.gray.opacity(0.4))
            HStack {
                Button(model.t("Fill the fields from this reference")) { model.fillFromReference(overwrite: true) }
                    .disabled((model.manual?.ready ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(model.t("Authors and year (and, when recognised, title, journal, volume, pages) are filled in; check them."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let err = model.manual?.error, !err.isEmpty { Text(err).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button(model.t("Cancel")) { model.manual = nil }.keyboardShortcut(.cancelAction)
                Button(model.t("Rename and add to list")) { model.submitManual() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 540)
    }
}

// MARK: Ayarlar sekmesi

struct SettingsView: View {
    @EnvironmentObject var model: Model

    private func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> { Binding(get: get, set: set) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                general
                naming
                citation
                lookup
                history
            }
            .padding(16)
        }
    }

    private var general: some View {
        GroupBox(model.t("General")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(model.t("Language"), selection: bind({ model.state.language ?? "en" }, { model.state.language = $0 })) {
                    Text("English").tag("en")
                    Text("Türkçe").tag("tr")
                }
                .pickerStyle(.segmented)
                Toggle(model.t("Also process the PDFs already inside a folder when it is added"), isOn: $model.state.processExisting)
                Toggle(model.t("Start at login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private var naming: some View {
        GroupBox(model.t("File naming")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(model.t("Pattern"), selection: bind({ model.state.namePreset ?? "author-year" }, { model.state.namePreset = $0 })) {
                    ForEach(Namer.presets, id: \.id) { p in Text(model.state.language == "tr" ? p.tr : p.en).tag(p.id) }
                    Text(model.t("Custom…")).tag("custom")
                }
                if (model.state.namePreset ?? "author-year") == "custom" {
                    TextField("{Author} ({Year}) - {Title}", text: bind({ model.state.nameTemplate ?? Namer.defaultTemplate }, { model.state.nameTemplate = $0 }))
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 4) {
                        ForEach(Namer.tokens, id: \.self) { tok in
                            Button(tok) { model.state.nameTemplate = (model.state.nameTemplate ?? "") + tok }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    Text(model.t("Click a field to add it, or type your own pattern (spaces, dashes, brackets are fine). A pattern needs at least {Author} or {Title}."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Stepper(value: bind({ model.state.titleMax ?? 60 }, { model.state.titleMax = $0 }), in: 20...150, step: 5) {
                    Text(model.t("Title length limit: %d characters", model.state.titleMax ?? 60))
                }
                Stepper(value: bind({ model.state.maxAuthors ?? 2 }, { model.state.maxAuthors = $0 }), in: 1...6) {
                    Text(model.t("List up to %d authors, then use “et al”", model.state.maxAuthors ?? 2))
                }
                HStack {
                    Picker(model.t("Between authors"), selection: bind({ model.state.andWord ?? "&" }, { model.state.andWord = $0 })) {
                        Text("A & B").tag("&"); Text("A and B").tag("and"); Text("A ve B").tag("ve"); Text("A, B").tag(",")
                    }
                    Picker(model.t("More authors"), selection: bind({ model.state.etAl ?? "et al" }, { model.state.etAl = $0 })) {
                        Text("A et al").tag("et al"); Text("A et al.").tag("et al."); Text("A vd.").tag("vd."); Text("A ...").tag("...")
                    }
                }
                Toggle(model.t("Keep accented letters (otherwise Turkish letters become plain ASCII)"), isOn: bind({ model.state.keepAccents ?? false }, { model.state.keepAccents = $0 }))
                Divider()
                Text(model.t("Preview: %@", model.namePreview)).font(.callout.monospaced()).textSelection(.enabled)
                Text(model.t("Files that are already named stay as they are. Duplicate names get a letter after the year (2013b).")).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private var citation: some View {
        GroupBox(model.t("Reference list")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(model.t("Write a reference list (.docx) in each folder, sorted alphabetically"), isOn: bind({ model.state.writeApa ?? true }, { model.state.writeApa = $0 }))
                Picker(model.t("Citation style"), selection: bind({ model.state.citeStyle ?? "apa" }, { model.state.citeStyle = $0 })) {
                    ForEach(CiteStyle.allCases) { s in Text(s.label).tag(s.rawValue) }
                }
                HStack {
                    Text(model.t("File name:"))
                    TextField(model.state.language == "tr" ? "Künyeler" : "References", text: bind({ model.state.refFileName ?? "" }, { model.state.refFileName = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder)
                    Text(".docx").foregroundStyle(.secondary)
                }
                Divider()
                Text(model.citePreview).font(.callout).textSelection(.enabled)
                Text(model.t("Titles in italics in the .docx. Style rules are approximations: please check against your style guide.")).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
        .onChange(of: model.state.citeStyle) { _ in model.regenerateRefFiles() }
        .onChange(of: model.state.refFileName) { _ in model.regenerateRefFiles() }
    }

    private var history: some View {
        GroupBox(model.t("History")) {
            VStack(alignment: .leading, spacing: 8) {
                Button(model.t("Clear history")) { model.clearAllHistory() }
                Text(model.t("Clears only what is shown in the lists. Files and reference lists stay as they are, but cleared activity can no longer be undone."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private var lookup: some View {
        GroupBox(model.t("Lookup")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(model.t("Search online (Crossref, OpenAlex): most accurate"), isOn: bind({ model.state.onlineLookup ?? true }, { model.state.onlineLookup = $0 }))
                HStack {
                    Text(model.t("OpenAlex key:")).font(.caption)
                    TextField(model.t("free key: openalex.org → Settings → API key"), text: bind({ model.state.openAlexKey ?? "" }, {
                        let v = $0.trimmingCharacters(in: .whitespaces); model.state.openAlexKey = v.isEmpty ? nil : v }))
                        .textFieldStyle(.roundedBorder)
                }.disabled(!(model.state.onlineLookup ?? true))
                Toggle(model.t("Guess unresolved files from the page text (less reliable; year becomes xxxx if missing)"), isOn: bind({ model.state.guessMode ?? false }, { model.state.guessMode = $0 }))
                Text(model.t("When online search is on, only the DOI and the title lines of the first page are sent; the file itself never leaves your Mac."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }
}

// MARK: Kaynakça sekmesi

struct RefView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(spacing: 12) {
            dropZone
            HStack {
                Image(systemName: "folder")
                Text(model.t("Download folder: %@", (model.refFolderURL.path as NSString).abbreviatingWithTildeInPath)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(model.t("Change…")) { model.chooseRefFolder() }
            }
            if model.refPagesWaiting > 0 {
                HStack {
                    Image(systemName: "safari").foregroundStyle(.orange)
                    Text(model.t("%d article pages are waiting to be opened (to download with your subscription)", model.refPagesWaiting)).font(.caption)
                    Spacer()
                    Button(model.t("Open next 5 pages")) { model.openNextPages(5) }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
            HStack {
                Spacer()
                Button(model.t("Clear history")) { model.clearRefItems() }
                    .disabled(model.refItems.isEmpty || model.refBusy)
            }
            List(model.refItems) { item in row(item) }.listStyle(.plain)
        }
        .padding(16)
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass").font(.system(size: 26))
            Text(model.t("Drop a reference list (.docx or .txt)")).font(.headline)
            Text(model.t("Open-access PDFs (article and working-paper versions) are downloaded; for articles that need a subscription the page is opened."))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.refBusy { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6])).foregroundStyle(.secondary))
        .dropDestination(for: URL.self, action: { urls, _ in
            guard let u = urls.first(where: { ["docx", "txt"].contains($0.pathExtension.lowercased()) }) else { return false }
            model.loadRefFile(u); return true
        })
        .onTapGesture {
            let p = NSOpenPanel()
            p.allowedContentTypes = [.plainText, UTType(filenameExtension: "docx")].compactMap { $0 }
            if p.runModal() == .OK, let u = p.url { model.loadRefFile(u) }
        }
    }

    private func row(_ item: RefItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(item.status)).foregroundStyle(color(item.status))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? item.text : item.title).lineLimit(2)
                if !item.note.isEmpty { Text(item.note).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if item.page != nil {
                Button(item.opened ? model.t("Reopen") : model.t("Open page")) { model.openPage(item.id) }.buttonStyle(.borderless)
            }
            if !model.refBusy {
                Button { model.removeRefItem(item.id) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(model.t("Remove this row from the list. Files and the reference list are not changed."))
            }
        }
    }

    private func icon(_ s: RefItem.Status) -> String {
        switch s {
        case .waiting: return "circle.dotted"
        case .working: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .pageOnly: return "safari"
        case .notFound: return "questionmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func color(_ s: RefItem.Status) -> Color {
        switch s {
        case .done: return .green
        case .pageOnly: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}
