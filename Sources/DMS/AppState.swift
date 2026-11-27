import AppKit
import Foundation
import SwiftUI

enum SidebarItem: Hashable {
    case dashboard
    case allFiles
    case category(FileCategory)
    case source(Int64)
    case tag(Int64)
    case defaultApps
    case duplicates
    case suggestions
    case rules
    case storageSettings
    case log
    case ai
    case processing
}

/// Zentrale Steuerung der App: Quellen, Suche, Auswahl, Hintergrundarbeit.
@MainActor
final class AppState: ObservableObject {
    let db: AppDatabase
    let indexer: Indexer
    let organizer: Organizer
    let analyzer: Analyzer

    @Published var sources: [Source] = []
    @Published var tags: [Tag] = []
    @Published var sidebar: SidebarItem? = .allFiles
    @Published var query: String = ""
    /// Filter in der Leiste über der Dateiliste (zusätzlich zur Seitenleiste)
    @Published var filterSourceId: Int64?
    @Published var filterCategory: FileCategory?
    @Published var filterExt: String?
    /// Nur Dateien eines Speicherorts (Mac, NAS, Google Drive), z. B. nach einem Sprung aus dem Dashboard
    @Published var filterKind: SourceKind?
    /// Darstellung der Dateien: Liste, Ordnerstruktur oder Gruppen
    @Published var browseMode: BrowseMode = .list
    /// Nach „In den Ordner springen“: diese Datei in der Ordneransicht aufklappen und zeigen
    @Published var revealPath: String?
    /// Ausgeschnittene oder kopierte Dateien und Ordner für „Einfügen“
    @Published var clipboard: (urls: [URL], cut: Bool)?
    @Published var fileOperationRunning = false
    @Published var rows: [FileRow] = []
    /// Zählt bei jedem neuen Suchergebnis hoch; günstiger Vergleich für Ansichten statt aller IDs
    private(set) var rowsVersion = 0
    /// Ordner, die in dieser Sitzung angelegt wurden und noch leer sind (damit sie im Baum erscheinen)
    @Published var createdFolders: Set<String> = []
    /// Ordner, in den „Neuer Ordner“ und „Einfügen“ zielen (aus der Auswahl in der Ordneransicht)
    @Published var targetFolder: URL?
    @Published var selection: Set<Int64> = []
    @Published var status: String = ""
    @Published var progress = IndexProgress(total: 0, pending: 0, withText: 0)
    @Published var errorMessage: String?

    private var watcher: FolderWatcher?
    private var searchTask: Task<Void, Never>?
    private var backgroundStarted = false
    private var captureWorker: Task<Void, Never>?
    private var taggingWorker: Task<Void, Never>?
    /// Wann die Hintergrundarbeit zuletzt etwas erledigt hat (für die Anzeige „läuft“)
    @Published var lastCaptureWork: Date?
    @Published var lastTaggingWork: Date?

    init() {
        do {
            db = try AppDatabase.openShared()
        } catch {
            fatalError("Datenbank konnte nicht geöffnet werden: \(error)")
        }
        indexer = Indexer(db: db)
        organizer = Organizer(db: db, indexer: indexer)
        analyzer = Analyzer(db: db)
        reloadSidebar()
        search()
    }

    // MARK: - Laden

    func reloadSidebar() {
        sources = (try? db.sources()) ?? []
        tags = (try? db.allTags()) ?? []
    }

    var selectedRows: [FileRow] {
        rows.filter { selection.contains($0.id) }
    }

    /// Startet die Suche mit den aktuellen Filtern (leicht verzögert beim Tippen).
    func search(debounce: Bool = false) {
        searchTask?.cancel()
        let parsed = SearchQuery(parsing: query)
        let text = parsed.text
        var sourceId: Int64?
        var tagId: Int64?
        var category: FileCategory?
        switch sidebar {
        case .source(let id): sourceId = id
        case .tag(let id): tagId = id
        case .category(let c): category = c
        default: break
        }
        // Filterleiste und Kürzel im Suchfeld (typ:, quelle:) grenzen weiter ein
        if let id = filterSourceId { sourceId = id }
        if let c = filterCategory { category = c }
        var ext = filterExt
        if let c = parsed.category { category = c }
        if let e = parsed.ext { ext = e }
        if let name = parsed.sourceName {
            // Unbekannte Quelle: id -1 liefert bewusst keine Treffer
            sourceId = source(named: name)?.id ?? -1
        }
        let kind = filterKind
        // Ordner und Gruppen brauchen alle Dateien, die Liste zeigt die besten Treffer
        let limit = browseMode == .list ? 500 : 50_000
        let db = self.db
        searchTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(250)) }
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .userInitiated) {
                (try? db.search(text, sourceId: sourceId, tagId: tagId, category: category, ext: ext,
                                kind: kind, limit: limit)) ?? []
            }.value
            if Task.isCancelled { return }
            self.rows = result
            self.rowsVersion &+= 1
            self.selection = self.selection.intersection(Set(result.map(\.id)))
        }
    }

    /// Quelle nach Namen: erst genau, dann Anfang, dann enthalten (ohne Groß/Klein).
    func source(named name: String) -> Source? {
        let n = name.lowercased()
        return sources.first { $0.name.lowercased() == n }
            ?? sources.first { $0.name.lowercased().hasPrefix(n) }
            ?? sources.first { $0.name.lowercased().contains(n) }
    }

    var hasActiveFilter: Bool { filterSourceId != nil || filterCategory != nil || filterExt != nil || filterKind != nil }

    func clearFilters() {
        filterSourceId = nil
        filterCategory = nil
        filterExt = nil
        filterKind = nil
    }

    // MARK: - Dateien und Ordner bearbeiten

    func copyToClipboard(_ urls: [URL], cut: Bool) {
        guard !urls.isEmpty else { return }
        clipboard = (urls, cut)
        // Auch für den Finder: dort lassen sich kopierte Dateien einsetzen
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects(urls as [NSURL])
        status = "\(urls.count) Element(e) \(cut ? "ausgeschnitten" : "kopiert")"
    }

    func paste(into folder: URL) {
        guard let clip = clipboard else { return }
        if clip.cut {
            move(clip.urls, into: folder)
            clipboard = nil
        } else {
            copy(clip.urls, into: folder)
        }
    }

    func move(_ urls: [URL], into folder: URL) {
        runFileOperation("verschoben") { $0.move(urls, into: folder) }
    }

    func copy(_ urls: [URL], into folder: URL) {
        runFileOperation("kopiert") { $0.copy(urls, into: folder) }
    }

    /// Legt einen neuen Ordner an. Gibt eine Fehlermeldung zurück oder nil.
    @discardableResult
    func createFolder(named name: String, in parent: URL) -> URL? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { return nil }
        let url = FileOps.uniqueURL(for: parent.appendingPathComponent(clean, isDirectory: true))
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            createdFolders.insert(url.path)
            status = "Ordner „\(url.lastPathComponent)“ angelegt"
            rowsVersion &+= 1
            objectWillChange.send()
            return url
        } catch {
            errorMessage = "Ordner konnte nicht angelegt werden: \(error.localizedDescription)"
            return nil
        }
    }

    func trash(_ urls: [URL]) {
        runFileOperation("in den Papierkorb gelegt") { $0.trash(urls) }
        selection = []
    }

    private func runFileOperation(_ verb: String, _ work: @escaping @Sendable (Organizer) -> Organizer.Outcome) {
        let organizer = self.organizer
        fileOperationRunning = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { work(organizer) }.value
            fileOperationRunning = false
            status = "\(outcome.done) Element(e) \(verb)"
            if !outcome.errors.isEmpty {
                errorMessage = "Nicht alles hat geklappt:\n" + outcome.errors.joined(separator: "\n")
            }
            search()
        }
    }

    // MARK: - Sprünge

    /// Alle Dateien eines Speicherorts als Ordnerstruktur zeigen (aus dem Dashboard).
    func showFiles(kind: SourceKind) {
        clearFilters()
        query = ""
        filterKind = kind
        browseMode = .folders
        sidebar = .allFiles
        search()
    }

    /// Eine Quelle als Ordnerstruktur zeigen.
    func showFolders(sourceId: Int64) {
        clearFilters()
        query = ""
        browseMode = .folders
        sidebar = .source(sourceId)
        search()
    }

    func showCategory(_ category: FileCategory) {
        clearFilters()
        query = ""
        browseMode = .list
        sidebar = .category(category)
        search()
    }

    /// Zur Datei in ihrem Ordner springen: Quelle wählen, Ordneransicht, Pfad aufklappen.
    func jumpToFolder(_ row: FileRow) {
        clearFilters()
        query = ""
        browseMode = .folders
        revealPath = row.file.path
        selection = [row.id]
        if sidebar == .source(row.file.sourceId) {
            search()
        } else {
            sidebar = .source(row.file.sourceId)
            search()
        }
    }

    /// Dateien am Speicherort löschen: Sie wandern in den Papierkorb (auf dem NAS in „DMS-Papierkorb“)
    /// und lassen sich im Protokoll wiederherstellen.
    func delete(_ rows: [FileRow]) {
        let errors = organizer.trashDuplicates(rows.compactMap(\.file.id))
        selection.subtract(rows.map(\.id))
        if !errors.isEmpty {
            errorMessage = "Nicht gelöscht:\n" + errors.joined(separator: "\n")
        }
        status = errors.isEmpty ? "\(rows.count) Datei(en) in den Papierkorb gelegt" : status
        search()
    }

    // MARK: - Quellen

    func addSourceWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Hinzufügen"
        panel.message = "Wähle Ordner auf dem Mac, auf CAWServer oder im Google-Drive-Ordner."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addSource(url) }
    }

    func addSource(_ url: URL) {
        let detected = SourceDetector.detect(url)
        var source = Source(id: nil, name: url.lastPathComponent, kind: detected.kind, path: url.path,
                            remoteURL: detected.remoteURL, lastScan: nil)
        do {
            try db.writer.write { db in try source.insert(db) }
        } catch {
            errorMessage = "Der Ordner ist schon eingebunden oder konnte nicht gespeichert werden."
            return
        }
        reloadSidebar()
        restartWatcher()
        scan(source)
    }

    func removeSource(_ source: Source) {
        _ = try? db.writer.write { db in try source.delete(db) }
        if let id = source.id, sidebar == .source(id) { sidebar = .allFiles }
        if let id = source.id, filterSourceId == id { filterSourceId = nil }
        reloadSidebar()
        restartWatcher()
        search()
    }

    func scan(_ source: Source) {
        let indexer = self.indexer
        status = "Scanne \(source.name) …"
        Task.detached(priority: .utility) {
            do {
                let count = try indexer.scan(source) { n in
                    Task { @MainActor in self.status = "Scanne \(source.name): \(n) Dateien" }
                }
                await MainActor.run {
                    self.status = "\(source.name): \(count) Dateien erfasst"
                    self.reloadSidebar()
                    self.search()
                }
            } catch {
                await MainActor.run { self.status = error.localizedDescription }
            }
        }
    }

    func scanAll() {
        for source in sources { scan(source) }
    }

    // MARK: - Hintergrundarbeit

    func startBackgroundWork() {
        guard !backgroundStarted else { return }
        backgroundStarted = true
        restartWatcher()
        scanAll()

        startCaptureWorker()
        startTaggingWorker()

        // Fortschritt anzeigen
        Task {
            while true {
                let db = self.db
                if let p = await Task.detached(operation: { try? db.progress() }).value, p != self.progress {
                    // Nur bei Änderung veröffentlichen, sonst zeichnen alle Ansichten alle 3 Sekunden neu
                    self.progress = p
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }

        // NAS regelmäßig abgleichen (stündlich)
        Task {
            while true {
                try? await Task.sleep(for: .seconds(3600))
                for source in self.sources where source.kind == .nas {
                    self.scan(source)
                }
                self.planSuggestions()
            }
        }
    }

    /// Text auslesen, OCR, Prüfsummen, Versionen und freigegebene Vorschläge, solange etwas offen ist.
    private func startCaptureWorker() {
        captureWorker?.cancel()
        let indexer = self.indexer
        let organizer = self.organizer
        let db = self.db
        captureWorker = Task.detached(priority: .utility) { [weak self] in
            // Drei getrennte Abläufe, damit lange Prüfsummen (z. B. große Videos auf dem NAS)
            // die Texterkennung nicht aufhalten
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        let work = indexer.extractPending(limit: 48)
                        if work > 0 {
                            await MainActor.run { self?.markWork(\.lastCaptureWork) }
                        } else {
                            try? await Task.sleep(for: .seconds(15))
                        }
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        // Texterkennung hat Vorrang: Prüfsummen lesen ganze Dateien und bremsen das NAS
                        if let pending = try? db.progress().pending, pending > 0 {
                            try? await Task.sleep(for: .seconds(60))
                            continue
                        }
                        if organizer.hashCandidates(limit: 20) == 0 {
                            try? await Task.sleep(for: .seconds(30))
                        }
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        organizer.processQueue()
                        if organizer.snapshotVersions(limit: 10) == 0 {
                            try? await Task.sleep(for: .seconds(60))
                        }
                    }
                }
            }
        }
    }

    /// Lokale KI: Bilder erkennen, Dokumente zusammenfassen (nur wenn ein Modell verfügbar ist).
    private func startTaggingWorker() {
        taggingWorker?.cancel()
        let analyzer = self.analyzer
        taggingWorker = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                var work = analyzer.tagImages(limit: 10)
                work += await analyzer.summarizePending(limit: 1)
                work += await analyzer.describeImages(limit: 1)
                if work > 0 {
                    await MainActor.run { self?.markWork(\.lastTaggingWork) }
                } else {
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }

    /// Höchstens alle 10 Sekunden veröffentlichen, sonst zeichnen alle Ansichten ständig neu.
    private func markWork(_ key: ReferenceWritableKeyPath<AppState, Date?>) {
        if let last = self[keyPath: key], last.timeIntervalSinceNow > -10 { return }
        self[keyPath: key] = Date()
    }

    /// Alle Quellen neu einlesen und Dateien, die nicht gelesen werden konnten, erneut versuchen.
    func restartCapture() {
        let reset = (try? db.resetFailedCapture()) ?? 0
        restartWatcher()
        scanAll()
        startCaptureWorker()
        status = reset > 0 ? "Datenerfassung neu gestartet, \(reset) Dateien werden erneut gelesen" : "Datenerfassung neu gestartet"
    }

    /// Tagging neu anstoßen: fehlgeschlagene KI-Auswertungen erneut versuchen.
    func restartTagging() {
        let reset = (try? db.resetFailedTagging()) ?? 0
        startTaggingWorker()
        status = reset > 0 ? "Tagging neu gestartet, \(reset) Dateien werden erneut ausgewertet" : "Tagging neu gestartet"
    }

    private func restartWatcher() {
        watcher?.stop()
        let watched = sources.filter { $0.kind != .nas && $0.isReachable }
        let indexer = self.indexer
        watcher = FolderWatcher(paths: watched.map(\.path)) { [weak self] paths in
            indexer.refresh(paths: paths, sources: watched)
            // Viele Änderungen kurz hintereinander (z. B. beim Verschieben) lösen nur eine Suche aus
            Task { @MainActor in self?.search(debounce: true) }
        }
    }

    // MARK: - Ablage

    /// Erstellt die Ablagevorschläge neu (im Hintergrund).
    func planSuggestions() {
        let organizer = self.organizer
        status = "Vorschläge werden berechnet …"
        Task.detached(priority: .utility) {
            let result = Result { try organizer.planSuggestions() }
            await MainActor.run {
                switch result {
                case .success(let n): self.status = "\(n) neue Vorschläge"
                case .failure(let e): self.status = "Vorschläge fehlgeschlagen: \(e.localizedDescription)"
                }
                self.objectWillChange.send()
            }
        }
    }

    /// Sorgt dafür, dass ein Ablageziel im Index liegt (sonst wird es als Quelle hinzugefügt).
    func ensureIndexed(_ path: String?) {
        guard let path, !path.isEmpty, !sources.contains(where: { $0.contains(path) }) else { return }
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        addSource(URL(fileURLWithPath: path, isDirectory: true))
    }

    func setVersioning(_ source: Source, _ on: Bool) {
        guard let id = source.id else { return }
        try? db.writer.write { db in
            try db.execute(sql: "UPDATE source SET versioning = ? WHERE id = ?", arguments: [on, id])
        }
        reloadSidebar()
    }

    // MARK: - Dateien

    func open(_ row: FileRow) {
        NSWorkspace.shared.open(row.file.url)
        if let id = row.file.id { try? db.recordUsage(fileId: id, kind: "opened") }
    }

    func reveal(_ rows: [FileRow]) {
        NSWorkspace.shared.activateFileViewerSelecting(rows.map(\.file.url))
    }

    func addTag(_ name: String, to rows: [FileRow]) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let ids = rows.compactMap(\.file.id)
        do {
            try db.addTag(clean, to: ids)
            for row in rows { FinderTags.add(clean, to: row.file.url) }
        } catch {
            errorMessage = "Tag konnte nicht gespeichert werden."
        }
        reloadSidebar()
        objectWillChange.send()
    }

    func removeTag(_ tag: Tag, from rows: [FileRow]) {
        guard let tagId = tag.id else { return }
        try? db.removeTag(tagId, from: rows.compactMap(\.file.id))
        for row in rows { FinderTags.remove(tag.name, from: row.file.url) }
        reloadSidebar()
        objectWillChange.send()
    }
}

/// Spiegelt Tags als Finder-Tags auf die Datei, damit sie auch im Finder sichtbar sind.
enum FinderTags {
    static func current(_ url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    static func add(_ name: String, to url: URL) {
        var tags = current(url)
        guard !tags.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        tags.append(name)
        try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    static func remove(_ name: String, from url: URL) {
        let tags = current(url).filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }
}
