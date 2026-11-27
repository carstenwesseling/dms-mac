import CoreServices
import Foundation
import GRDB
import UniformTypeIdentifiers

/// Scannt Quellen, hält den Index aktuell und liest Text aus den Dateien.
/// Dateien werden dabei nie verändert oder verschoben.
final class Indexer: @unchecked Sendable {
    let db: AppDatabase

    private let lock = NSLock()
    private var scanning: Set<Int64> = []

    init(db: AppDatabase) {
        self.db = db
    }

    enum IndexerError: LocalizedError {
        case offline(String)

        var errorDescription: String? {
            switch self {
            case .offline(let name): return "\(name) ist nicht erreichbar."
            }
        }
    }

    // MARK: - Datei-Informationen

    struct FileInfo {
        var path: String
        var name: String
        var ext: String
        var typeIdentifier: String?
        var size: Int64
        var modified: Date
        var created: Date?
        var finderTags: [String]
        var cloudOnly: Bool
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
        .contentTypeKey, .tagNamesKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]

    static func info(for url: URL) -> FileInfo? {
        let name = url.lastPathComponent
        // Office-Sperrdateien und temporäre Dateien überspringen
        if name.hasPrefix("~$") || name.hasPrefix(".") || name.hasSuffix(".tmp") { return nil }
        guard let values = try? url.resourceValues(forKeys: resourceKeys), values.isRegularFile == true else { return nil }
        var cloudOnly = false
        if values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus, status != .current {
            cloudOnly = true
        }
        return FileInfo(
            path: url.path,
            name: name,
            ext: url.pathExtension.lowercased(),
            typeIdentifier: values.contentType?.identifier,
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
            created: values.creationDate,
            finderTags: values.tagNames ?? [],
            cloudOnly: cloudOnly
        )
    }

    /// "Zuletzt benutzt" aus Spotlight (nur für Dateien auf dem Mac verlässlich).
    static func spotlightLastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: - Quelle scannen

    /// Scannt eine Quelle komplett. Läuft synchron, also aus einem Hintergrund-Task aufrufen.
    @discardableResult
    func scan(_ source: Source, progress: ((Int) -> Void)? = nil) throws -> Int {
        guard let sourceId = source.id else { return 0 }

        lock.lock()
        if scanning.contains(sourceId) { lock.unlock(); return 0 }
        scanning.insert(sourceId)
        lock.unlock()
        defer { lock.lock(); scanning.remove(sourceId); lock.unlock() }

        if !source.isReachable, source.kind == .nas, let remote = source.remoteURL {
            NASMounter.mount(remote)
        }
        guard source.isReachable else { throw IndexerError.offline(source.name) }

        let mark = Int64(Date().timeIntervalSince1970 * 1000)
        var known = try knownFiles(sourceId: sourceId)

        guard let enumerator = FileManager.default.enumerator(
            at: source.url,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var batch: [FileInfo] = []
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            guard let info = Self.info(for: url) else { continue }
            batch.append(info)
            if batch.count >= 500 {
                try write(batch, sourceId: sourceId, kind: source.kind, mark: mark, known: &known)
                count += batch.count
                progress?(count)
                batch.removeAll(keepingCapacity: true)
            }
        }
        try write(batch, sourceId: sourceId, kind: source.kind, mark: mark, known: &known)
        count += batch.count
        progress?(count)

        // Was beim Scan nicht gefunden wurde, ist vermutlich gelöscht oder verschoben worden.
        // Auf dem NAS können Ordner beim Auflisten aber auch nur kurz nicht antworten; deshalb jede
        // fehlende Datei einzeln prüfen und nur entfernen, wenn sie wirklich weg ist. So bleiben
        // Prüfsummen, Texte und Tags bei Netzwerkaussetzern erhalten.
        let missing: [(Int64, String)] = try db.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT id, path FROM file WHERE sourceId = ? AND scanMark != ?", arguments: [sourceId, mark])
                .map { ($0["id"], $0["path"]) }
        }
        guard source.isReachable else { return count }
        let fm = FileManager.default
        var gone: [Int64] = []
        var still: [Int64] = []
        for (id, path) in missing {
            if fm.fileExists(atPath: path) { still.append(id) } else { gone.append(id) }
        }
        // Ist die Quelle während der Prüfung weggefallen, lieber nichts löschen
        guard source.isReachable else { return count }
        try db.writer.write { db in
            for chunk in gone.chunked(into: 400) {
                try db.execute(sql: "DELETE FROM file WHERE id IN (\(chunk.map { _ in "?" }.joined(separator: ",")))",
                               arguments: StatementArguments(chunk))
            }
            for chunk in still.chunked(into: 400) {
                var args: [Int64] = [mark]
                args += chunk
                try db.execute(sql: "UPDATE file SET scanMark = ? WHERE id IN (\(chunk.map { _ in "?" }.joined(separator: ",")))",
                               arguments: StatementArguments(args))
            }
            try db.execute(sql: "UPDATE source SET lastScan = ? WHERE id = ?", arguments: [Date(), sourceId])
        }
        return count
    }

    private struct Known {
        var id: Int64
        var size: Int64
        var modified: Date
        var state: TextState
    }

    private func knownFiles(sourceId: Int64) throws -> [String: Known] {
        try db.reader.read { db in
            var result: [String: Known] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT id, path, size, modified, textState FROM file WHERE sourceId = ?", arguments: [sourceId])
            while let row = try rows.next() {
                let state = TextState(rawValue: row["textState"]) ?? .pending
                result[row["path"]] = Known(id: row["id"], size: row["size"], modified: row["modified"], state: state)
            }
            return result
        }
    }

    private func write(_ batch: [FileInfo], sourceId: Int64, kind: SourceKind, mark: Int64, known: inout [String: Known]) throws {
        guard !batch.isEmpty else { return }
        var unchanged: [Int64] = []
        var changed: [(FileInfo, Known?)] = []

        for info in batch {
            if let existing = known[info.path],
               existing.size == info.size,
               abs(existing.modified.timeIntervalSince(info.modified)) < 1,
               !(existing.state == .cloudOnly && !info.cloudOnly) {
                unchanged.append(existing.id)
            } else {
                changed.append((info, known[info.path]))
            }
        }

        let readsSpotlight = kind != .nas
        let lastUsed: [String: Date] = readsSpotlight
            ? Dictionary(uniqueKeysWithValues: changed.compactMap { info, _ in Self.spotlightLastUsed(info.path).map { (info.path, $0) } })
            : [:]

        let written: [(String, Known)] = try db.writer.write { db in
            if !unchanged.isEmpty {
                for chunk in unchanged.chunked(into: 400) {
                    let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                    var args: [(any DatabaseValueConvertible)?] = [mark]
                    args.append(contentsOf: chunk.map { $0 as (any DatabaseValueConvertible)? })
                    try db.execute(sql: "UPDATE file SET scanMark = ? WHERE id IN (\(placeholders))", arguments: StatementArguments(args))
                }
            }
            var out: [(String, Known)] = []
            for (info, existing) in changed {
                let id = try Self.upsert(db, info: info, existingId: existing?.id, sourceId: sourceId, mark: mark, lastUsed: lastUsed[info.path])
                let state = try String.fetchOne(db, sql: "SELECT textState FROM file WHERE id = ?", arguments: [id]).flatMap(TextState.init) ?? .pending
                out.append((info.path, Known(id: id, size: info.size, modified: info.modified, state: state)))
            }
            return out
        }
        for (path, k) in written { known[path] = k }
    }

    /// Fügt eine Datei ein oder aktualisiert sie. Inhalt wird neu ausgewertet.
    private static func upsert(_ db: Database, info: FileInfo, existingId: Int64?, sourceId: Int64, mark: Int64, lastUsed: Date?) throws -> Int64 {
        let state: TextState
        if info.cloudOnly {
            state = .cloudOnly
        } else if !TextExtractor.supports(ext: info.ext) || info.size > TextExtractor.maxFileSize {
            state = .skipped
        } else {
            state = .pending
        }

        var record = FileRecord(
            id: existingId,
            sourceId: sourceId,
            path: info.path,
            name: info.name,
            ext: info.ext,
            typeIdentifier: info.typeIdentifier,
            size: info.size,
            modified: info.modified,
            created: info.created,
            lastUsed: lastUsed,
            contentHash: nil,
            textState: state,
            scanMark: mark
        )
        if existingId != nil {
            if lastUsed == nil {
                record.lastUsed = try Date.fetchOne(db, sql: "SELECT lastUsed FROM file WHERE id = ?", arguments: [existingId])
            }
            try record.update(db)
            try db.execute(sql: "DELETE FROM content WHERE fileId = ?", arguments: [existingId])
            try db.execute(sql: "DELETE FROM analysis WHERE fileId = ?", arguments: [existingId])
        } else {
            try record.insert(db)
        }
        let id = record.id!

        // Vorhandene Finder-Tags übernehmen
        for tagName in info.finderTags where !tagName.isEmpty {
            let tagId = try AppDatabase.tagId(db, name: tagName)
            try db.execute(sql: "INSERT OR IGNORE INTO fileTag(fileId, tagId) VALUES (?, ?)", arguments: [id, tagId])
        }
        try AppDatabase.reindexFTS(db, fileId: id)
        return id
    }

    // MARK: - Einzelne Änderungen (aus FSEvents)

    /// Aktualisiert den Index für geänderte Pfade, ohne die ganze Quelle neu zu scannen.
    func refresh(paths: [String], sources: [Source]) {
        let fm = FileManager.default
        var knownCache: [Int64: [String: Known]] = [:]
        func cachedKnown(_ sourceId: Int64) throws -> [String: Known] {
            if let cached = knownCache[sourceId] { return cached }
            let loaded = try knownFiles(sourceId: sourceId)
            knownCache[sourceId] = loaded
            return loaded
        }
        // Nur oberste Pfade: ein Ordner deckt Änderungen darin ab
        let unique = Set(paths)
        let topPaths = unique.filter { path in !unique.contains { path.hasPrefix($0 + "/") } }
        for path in topPaths {
            guard let source = sources.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }),
                  let sourceId = source.id else { continue }
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
            do {
                if !exists {
                    try db.writer.write { db in
                        try db.execute(sql: "DELETE FROM file WHERE path = ? OR path LIKE ?", arguments: [path, path + "/%"])
                    }
                } else if isDir.boolValue {
                    var known = try cachedKnown(sourceId)
                    let mark = Int64(Date().timeIntervalSince1970 * 1000)
                    var batch: [FileInfo] = []
                    if let en = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: Array(Self.resourceKeys),
                                              options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) {
                        while let url = en.nextObject() as? URL {
                            if let info = Self.info(for: url) { batch.append(info) }
                        }
                    }
                    try write(batch, sourceId: sourceId, kind: source.kind, mark: mark, known: &known)
                    knownCache[sourceId] = known
                } else if let info = Self.info(for: URL(fileURLWithPath: path)) {
                    var known = try cachedKnown(sourceId)
                    let mark = Int64(Date().timeIntervalSince1970 * 1000)
                    try write([info], sourceId: sourceId, kind: source.kind, mark: mark, known: &known)
                    knownCache[sourceId] = known
                }
            } catch {
                NSLog("DMS refresh failed for \(path): \(error)")
            }
        }
    }

    // MARK: - Textauswertung

    /// Wertet bis zu `limit` offene Dateien aus. Gibt die Anzahl bearbeiteter Dateien zurück.
    func extractPending(limit: Int = 20) -> Int {
        let reachable: [Int64]
        do {
            reachable = try db.sources().filter(\.isReachable).compactMap(\.id)
        } catch { return 0 }
        guard !reachable.isEmpty else { return 0 }

        let files: [FileRecord]
        do {
            // Dateien auf dem Mac zuerst, das NAS danach; jeweils neueste zuerst
            files = try db.reader.read { db in
                try FileRecord.fetchAll(db, sql: """
                    SELECT file.* FROM file JOIN source ON source.id = file.sourceId
                    WHERE file.textState = 'pending' AND file.sourceId IN (\(reachable.map(String.init).joined(separator: ",")))
                    ORDER BY CASE source.kind WHEN 'local' THEN 0 WHEN 'googleDrive' THEN 1 ELSE 2 END, file.modified DESC
                    LIMIT ?
                    """, arguments: [limit])
            }
        } catch { return 0 }

        // Viele Dateien gleichzeitig lesen: die meiste Zeit wartet die App auf das NAS, nicht auf die CPU
        let results = Locked([(TextState, TextExtractor.Result?)?](repeating: nil, count: files.count))
        Self.parallel(files.count, width: Self.readWidth) { i in
            let file = files[i]
            var state: TextState
            var result: TextExtractor.Result?
            do {
                result = try autoreleasepool { try TextExtractor.extract(from: file.url, ext: file.ext) }
                if let r = result, !r.text.isEmpty { state = .done } else { state = .empty }
            } catch {
                state = .failed
            }
            results.withLock { $0[i] = (state, result) }
        }

        let finished = results.withLock { $0 }
        // Alles in einem Schreibvorgang sichern statt einzeln pro Datei
        do {
            try db.writer.write { db in
                for (file, entry) in zip(files, finished) {
                    guard let id = file.id, let entry else { continue }
                    let (state, result) = entry
                    if let result, state == .done {
                        try db.execute(sql: "INSERT OR REPLACE INTO content(fileId, body, method) VALUES (?, ?, ?)",
                                       arguments: [id, result.text, result.method])
                    }
                    try db.execute(sql: "UPDATE file SET textState = ? WHERE id = ?", arguments: [state.rawValue, id])
                    try AppDatabase.reindexFTS(db, fileId: id)
                }
            }
        } catch {
            NSLog("DMS could not save extracted text: \(error)")
        }
        return files.count
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

extension Indexer {
    /// Gleichzeitige Lesevorgänge bei der Texterkennung
    static let readWidth = 16

    /// Führt `body` für 0..<count aus, höchstens `width` gleichzeitig, und wartet auf alle.
    /// Anders als concurrentPerform nicht auf die Zahl der Kerne begrenzt.
    static func parallel(_ count: Int, width: Int, _ body: @escaping @Sendable (Int) -> Void) {
        guard count > 0 else { return }
        let queue = DispatchQueue(label: "dms.parallel", qos: .utility, attributes: .concurrent)
        let slots = DispatchSemaphore(value: width)
        let group = DispatchGroup()
        for i in 0..<count {
            slots.wait()
            queue.async(group: group) {
                defer { slots.signal() }
                body(i)
            }
        }
        group.wait()
    }
}

/// Einfacher, threadsicherer Behälter für Ergebnisse aus parallelen Läufen.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
