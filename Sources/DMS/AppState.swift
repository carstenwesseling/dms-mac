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
}

/// Zentrale Steuerung der App: Quellen, Suche, Auswahl, Hintergrundarbeit.
@MainActor
final class AppState: ObservableObject {
    let db: AppDatabase
    let indexer: Indexer

    @Published var sources: [Source] = []
    @Published var tags: [Tag] = []
    @Published var sidebar: SidebarItem? = .allFiles
    @Published var query: String = ""
    @Published var rows: [FileRow] = []
    @Published var selection: Set<Int64> = []
    @Published var status: String = ""
    @Published var progress = IndexProgress(total: 0, pending: 0, withText: 0)
    @Published var errorMessage: String?

    private var watcher: FolderWatcher?
    private var searchTask: Task<Void, Never>?
    private var backgroundStarted = false

    init() {
        do {
            db = try AppDatabase.openShared()
        } catch {
            fatalError("Datenbank konnte nicht geöffnet werden: \(error)")
        }
        indexer = Indexer(db: db)
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
        let text = query
        var sourceId: Int64?
        var tagId: Int64?
        var category: FileCategory?
        switch sidebar {
        case .source(let id): sourceId = id
        case .tag(let id): tagId = id
        case .category(let c): category = c
        default: break
        }
        let db = self.db
        searchTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(250)) }
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .userInitiated) {
                (try? db.search(text, sourceId: sourceId, tagId: tagId, category: category)) ?? []
            }.value
            if Task.isCancelled { return }
            self.rows = result
            self.selection = self.selection.intersection(Set(result.map(\.id)))
        }
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

        // Text auslesen und OCR, solange etwas offen ist
        let indexer = self.indexer
        Task.detached(priority: .background) {
            while true {
                let done = indexer.extractPending(limit: 20)
                if done == 0 {
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }

        // Fortschritt anzeigen
        Task {
            while true {
                let db = self.db
                if let p = await Task.detached(operation: { try? db.progress() }).value {
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
            }
        }
    }

    private func restartWatcher() {
        watcher?.stop()
        let watched = sources.filter { $0.kind != .nas && $0.isReachable }
        let indexer = self.indexer
        watcher = FolderWatcher(paths: watched.map(\.path)) { [weak self] paths in
            indexer.refresh(paths: paths, sources: watched)
            Task { @MainActor in self?.search() }
        }
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
