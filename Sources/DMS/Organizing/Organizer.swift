import Foundation
import GRDB

/// Dubletten, Nutzungsstufen, Regeln, Ablagevorschläge, Versionen und Protokoll.
/// Dateien werden nur bewegt, wenn ein Vorschlag freigegeben wurde (oder eine Regel ausdrücklich automatisch ist).
final class Organizer: @unchecked Sendable {
    let db: AppDatabase
    let indexer: Indexer

    init(db: AppDatabase, indexer: Indexer) {
        self.db = db
        self.indexer = indexer
    }

    static let versionableExtensions = ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pdf", "txt", "md", "rtf", "pages", "numbers", "key", "odt", "ods", "csv"]
    static let maxVersionSize: Int64 = 100 * 1024 * 1024

    // MARK: - Einstellungen

    func settings() -> StorageSettings {
        let json = try? db.reader.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [StorageSettings.key])
        }
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(StorageSettings.self, from: data) else { return StorageSettings() }
        return decoded
    }

    func save(_ settings: StorageSettings) throws {
        let data = try JSONEncoder().encode(settings)
        let json = String(decoding: data, as: UTF8.self)
        try db.writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO setting(key, value) VALUES (?, ?)", arguments: [StorageSettings.key, json])
        }
    }

    // MARK: - Nutzungsstufen

    static func tier(lastActivity: Date, now: Date = Date(), settings: StorageSettings) -> StorageTier {
        let days = now.timeIntervalSince(lastActivity) / 86_400
        if days <= Double(settings.macDays) { return .mac }
        if days <= Double(settings.driveDays) { return .drive }
        return .nas
    }

    static func tier(of kind: SourceKind) -> StorageTier {
        switch kind {
        case .local: return .mac
        case .googleDrive: return .drive
        case .nas: return .nas
        }
    }

    static func lastActivity(_ file: FileRecord) -> Date {
        max(file.modified, file.lastUsed ?? .distantPast)
    }

    static func target(for tier: StorageTier, in settings: StorageSettings) -> String? {
        switch tier {
        case .mac: return settings.macTarget
        case .drive: return settings.driveTarget
        case .nas: return settings.nasTarget
        }
    }

    /// Zielpfad: Ablageziel / Quellname / Pfad innerhalb der Quelle.
    static func destination(for file: FileRecord, source: Source, root: String) -> String {
        var relative = String(file.path.dropFirst(source.path.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return URL(fileURLWithPath: root).appendingPathComponent(source.name).appendingPathComponent(relative).path
    }

    // MARK: - Prüfsummen

    /// Berechnet Prüfsummen für Dateien, bei denen es sich lohnt:
    /// gleiche Größe wie eine andere Datei (mögliche Dublette) oder Versionierung aktiv.
    func hashCandidates(limit: Int = 40) -> Int {
        guard let reachable = try? db.sources().filter(\.isReachable).compactMap(\.id), !reachable.isEmpty else { return 0 }
        let idList = reachable.map(String.init).joined(separator: ",")
        let extList = Self.versionableExtensions.map { "'\($0)'" }.joined(separator: ",")
        let files: [FileRecord] = (try? db.reader.read { db in
            try FileRecord.fetchAll(db, sql: """
                SELECT file.* FROM file JOIN source ON source.id = file.sourceId
                WHERE file.contentHash IS NULL AND file.size > 0 AND file.textState != 'cloudOnly'
                  AND file.sourceId IN (\(idList))
                  AND (file.size IN (SELECT size FROM file WHERE size > 0 GROUP BY size HAVING COUNT(*) > 1)
                       OR (source.versioning = 1 AND file.ext IN (\(extList)) AND file.size <= ?))
                LIMIT ?
                """, arguments: [Self.maxVersionSize, limit])
        }) ?? []

        // Vier Dateien gleichzeitig; beim NAS wartet das Lesen vor allem auf das Netzwerk
        let hashes = Locked([String?](repeating: nil, count: files.count))
        Indexer.parallel(files.count, width: 4) { i in
            let hash = try? FileOps.sha256(files[i].url)
            hashes.withLock { $0[i] = hash }
        }
        let results = hashes.withLock { $0 }
        try? db.writer.write { db in
            for (file, hash) in zip(files, results) {
                guard let id = file.id else { continue }
                // Nicht lesbar: leere Prüfsumme, damit die Datei nicht endlos neu versucht wird
                try db.execute(sql: "UPDATE file SET contentHash = ? WHERE id = ?", arguments: [hash ?? "", id])
            }
        }
        return files.count
    }

    // MARK: - Dubletten

    func duplicateGroups() throws -> [DuplicateGroup] {
        let rows = try db.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT file.*, source.name AS sourceName FROM file
                JOIN source ON source.id = file.sourceId
                WHERE file.contentHash IN (
                    SELECT contentHash FROM file WHERE contentHash IS NOT NULL AND contentHash != ''
                    GROUP BY contentHash HAVING COUNT(*) > 1)
                ORDER BY file.size DESC, file.contentHash, file.modified
                """)
        }
        var groups: [String: [FileRow]] = [:]
        var order: [String] = []
        for row in rows {
            let file = try FileRecord(row: row)
            guard let hash = file.contentHash else { continue }
            if groups[hash] == nil { order.append(hash) }
            groups[hash, default: []].append(FileRow(file: file, sourceName: row["sourceName"], snippet: nil))
        }
        return order.map { DuplicateGroup(hash: $0, files: groups[$0] ?? []) }
    }

    /// Welche Kopie behalten? Bevorzugt die, die schon am passenden Ort liegt, sonst die älteste.
    static func recommendedKeep(_ group: DuplicateGroup, sources: [Source], settings: StorageSettings) -> Int64? {
        let byId = Dictionary(uniqueKeysWithValues: sources.compactMap { s in s.id.map { ($0, s) } })
        let fitting = group.files.filter { row in
            guard let source = byId[row.file.sourceId] else { return false }
            return tier(of: source.kind) == tier(lastActivity: lastActivity(row.file), settings: settings)
        }
        let candidates = fitting.isEmpty ? group.files : fitting
        return candidates.min { a, b in
            (a.file.created ?? a.file.modified) < (b.file.created ?? b.file.modified)
        }?.file.id
    }

    /// Legt die gewählten Dubletten in den Papierkorb (rückgängig machbar über das Protokoll).
    func trashDuplicates(_ fileIds: [Int64]) -> [String] {
        var errors: [String] = []
        for id in fileIds {
            guard let file = try? db.reader.read({ db in try FileRecord.fetchOne(db, key: id) }) else { continue }
            do {
                let trash = try FileOps.moveToTrash(file.url)
                try db.writer.write { db in
                    var entry = ActionLogEntry(id: nil, at: Date(), kind: "trash", fromPath: file.path, toPath: trash, trashPath: trash, undone: false)
                    try entry.insert(db)
                    _ = try FileRecord.deleteOne(db, key: id)
                }
            } catch {
                errors.append("\(file.name): \(error.localizedDescription)")
            }
        }
        return errors
    }

    // MARK: - Regeln

    func rules() throws -> [Rule] {
        try db.reader.read { db in try Rule.order(Column("position"), Column("id")).fetchAll(db) }
    }

    func save(_ rule: Rule) throws {
        var rule = rule
        try db.writer.write { db in try rule.save(db) }
    }

    func delete(_ rule: Rule) throws {
        _ = try db.writer.write { db in try rule.delete(db) }
    }

    /// Datei-IDs, auf die eine Regel zutrifft.
    func matches(_ rule: Rule, in db: Database) throws -> Set<Int64> {
        let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        switch rule.field {
        case .name:
            return Set(try Int64.fetchAll(db, sql: "SELECT id FROM file WHERE name LIKE ?", arguments: ["%\(value)%"]))
        case .ext:
            let ext = value.lowercased().replacingOccurrences(of: ".", with: "")
            return Set(try Int64.fetchAll(db, sql: "SELECT id FROM file WHERE ext = ?", arguments: [ext]))
        case .tag:
            return Set(try Int64.fetchAll(db, sql: """
                SELECT fileTag.fileId FROM fileTag JOIN tag ON tag.id = fileTag.tagId WHERE tag.name = ? COLLATE NOCASE
                """, arguments: [value]))
        case .content:
            let phrase = "body : \"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return Set(try Int64.fetchAll(db, sql: "SELECT rowid FROM file_fts WHERE file_fts MATCH ?", arguments: [phrase]))
        }
    }

    // MARK: - Vorschläge planen

    /// Erstellt Vorschläge neu: Tags und feste Ablageorte aus Regeln, sonst Ablage nach Nutzungsstufe.
    /// Abgelehnte Vorschläge werden nicht erneut vorgeschlagen.
    @discardableResult
    func planSuggestions(now: Date = Date()) throws -> Int {
        let settings = settings()
        let sources = try db.sources()
        let sourceById = Dictionary(uniqueKeysWithValues: sources.compactMap { s in s.id.map { ($0, s) } })
        let rules = try rules().filter(\.enabled)
        var autoTags: [(String, [Int64])] = []

        let created: Int = try db.writer.write { db in
            try db.execute(sql: "DELETE FROM suggestion WHERE status = 'open' AND (kind = 'move' OR (kind = 'tag' AND reason LIKE 'Regel%'))")

            var ruleMatches: [(Rule, Set<Int64>)] = []
            for rule in rules { ruleMatches.append((rule, try self.matches(rule, in: db))) }

            var count = 0
            func add(_ fileId: Int64, _ kind: SuggestionKind, _ target: String, _ reason: String, automatic: Bool) throws {
                var s = Suggestion(id: nil, fileId: fileId, kind: kind, target: target, reason: reason,
                                   status: automatic ? .queued : .open, detail: nil, createdAt: now)
                try s.insert(db, onConflict: .ignore)
                if db.changesCount > 0 { count += 1 }
            }

            let files = try FileRecord.fetchAll(db)
            for file in files {
                guard let id = file.id, let source = sourceById[file.sourceId] else { continue }
                let fileDir = file.url.deletingLastPathComponent().path

                // 1. Regeln: Tags
                for (rule, ids) in ruleMatches where ids.contains(id) {
                    if let tag = rule.addTag?.trimmingCharacters(in: .whitespaces), !tag.isEmpty {
                        let has = try Bool.fetchOne(db, sql: """
                            SELECT EXISTS(SELECT 1 FROM fileTag JOIN tag ON tag.id = fileTag.tagId
                                          WHERE fileTag.fileId = ? AND tag.name = ? COLLATE NOCASE)
                            """, arguments: [id, tag]) ?? false
                        if !has {
                            if rule.automatic {
                                autoTags.append((tag, [id]))
                            } else {
                                try add(id, .tag, tag, "Regel „\(rule.name)“", automatic: false)
                            }
                        }
                    }
                }

                // 2. Fester Ablageort aus der ersten passenden Regel mit Ziel
                if let match = ruleMatches.first(where: { $0.1.contains(id) && !($0.0.targetPath ?? "").isEmpty }),
                   let targetRoot = match.0.targetPath {
                    let rule = match.0
                    if fileDir != targetRoot && !fileDir.hasPrefix(targetRoot + "/") {
                        let dest = URL(fileURLWithPath: targetRoot).appendingPathComponent(file.name).path
                        try add(id, .move, dest, "Regel „\(rule.name)“: fester Ablageort", automatic: rule.automatic)
                    }
                    continue
                }

                // 3. Nutzungsstufe
                guard file.textState != .cloudOnly || source.kind == .googleDrive else { continue }
                let activity = Self.lastActivity(file)
                let wanted = Self.tier(lastActivity: activity, now: now, settings: settings)
                let current = Self.tier(of: source.kind)
                guard wanted != current, let root = Self.target(for: wanted, in: settings), !root.isEmpty else { continue }
                if fileDir == root || fileDir.hasPrefix(root + "/") { continue }
                let days = Int(now.timeIntervalSince(activity) / 86_400)
                let reason = "Zuletzt genutzt vor \(days) Tagen, gehört auf \(wanted.label)"
                try add(id, .move, Self.destination(for: file, source: source, root: root), reason, automatic: false)
            }
            return count
        }

        for (tag, ids) in autoTags {
            try db.addTag(tag, to: ids)
            for id in ids {
                if let path = try db.reader.read({ db in try String.fetchOne(db, sql: "SELECT path FROM file WHERE id = ?", arguments: [id]) }) {
                    FinderTags.add(tag, to: URL(fileURLWithPath: path))
                }
            }
        }
        return created
    }

    func suggestions(status: [SuggestionStatus]) throws -> [SuggestionRow] {
        try db.reader.read { db in
            let list = status.map { "'\($0.rawValue)'" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT suggestion.id AS sId, suggestion.fileId AS sFileId, suggestion.kind AS sKind, suggestion.target AS sTarget,
                       suggestion.reason AS sReason, suggestion.status AS sStatus, suggestion.detail AS sDetail,
                       suggestion.createdAt AS sCreatedAt, file.*
                FROM suggestion JOIN file ON file.id = suggestion.fileId
                WHERE suggestion.status IN (\(list))
                ORDER BY CASE suggestion.kind WHEN 'tag' THEN 0 WHEN 'move' THEN 1 ELSE 2 END, file.path
                LIMIT 5000
                """)
            return try rows.map { row in
                let s = Suggestion(
                    id: row["sId"], fileId: row["sFileId"],
                    kind: SuggestionKind(rawValue: row["sKind"]) ?? .move,
                    target: row["sTarget"], reason: row["sReason"],
                    status: SuggestionStatus(rawValue: row["sStatus"]) ?? .open,
                    detail: row["sDetail"], createdAt: row["sCreatedAt"])
                return SuggestionRow(suggestion: s, file: try FileRecord(row: row))
            }
        }
    }

    func setStatus(_ ids: [Int64], _ status: SuggestionStatus) throws {
        try db.writer.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE suggestion SET status = ?, detail = NULL WHERE id = ?", arguments: [status.rawValue, id])
            }
        }
    }

    // MARK: - Ausführen

    /// Führt freigegebene Vorschläge aus. Ist das Ziel (z. B. CAWServer) nicht erreichbar,
    /// bleiben sie in der Warteschlange und werden beim nächsten Durchlauf erneut versucht.
    @discardableResult
    func processQueue() -> Int {
        guard let queued = try? suggestions(status: [.queued]), !queued.isEmpty else { return 0 }
        let sources = (try? db.sources()) ?? []
        var done = 0

        for row in queued {
            guard let sid = row.suggestion.id else { continue }
            let file = row.file
            do {
                switch row.suggestion.kind {
                case .tag:
                    try db.addTag(row.suggestion.target, to: [row.suggestion.fileId])
                    FinderTags.add(row.suggestion.target, to: file.url)

                case .trashDuplicate:
                    let errors = trashDuplicates([row.suggestion.fileId])
                    if let first = errors.first { throw NSError(domain: "DMS", code: 1, userInfo: [NSLocalizedDescriptionKey: first]) }

                case .move:
                    let target = row.suggestion.target
                    if !FileOps.isReachable(target) {
                        // NAS eventuell verbinden
                        for s in sources where s.kind == .nas && !s.isReachable {
                            if let remote = s.remoteURL { NASMounter.mount(remote) }
                        }
                        if !FileOps.isReachable(target) { continue }
                    }
                    if !FileManager.default.fileExists(atPath: file.path) && !FileOps.isReachable(file.path) { continue }
                    let result = try FileOps.safeMove(from: file.url, to: URL(fileURLWithPath: target))
                    try recordMove(file: file, from: file.path, result: result, sources: sources)
                }
                try db.writer.write { db in
                    try db.execute(sql: "UPDATE suggestion SET status = 'done', detail = NULL WHERE id = ?", arguments: [sid])
                }
                done += 1
            } catch {
                try? db.writer.write { db in
                    try db.execute(sql: "UPDATE suggestion SET status = 'failed', detail = ? WHERE id = ?",
                                   arguments: [error.localizedDescription, sid])
                }
            }
        }
        return done
    }

    /// Protokolliert eine Verschiebung und passt den Index an.
    private func recordMove(file: FileRecord, from: String, result: FileOps.MoveResult, sources: [Source]) throws {
        let newURL = URL(fileURLWithPath: result.finalPath)
        try db.writer.write { db in
            var entry = ActionLogEntry(id: nil, at: Date(), kind: "move", fromPath: from, toPath: result.finalPath,
                                       trashPath: result.trashPath, undone: false)
            try entry.insert(db)
            try db.execute(sql: "UPDATE fileVersion SET originalPath = ? WHERE originalPath = ?", arguments: [result.finalPath, from])
            guard let id = file.id else { return }
            if let dest = sources.first(where: { $0.contains(result.finalPath) }), let destId = dest.id {
                try db.execute(sql: "UPDATE file SET path = ?, name = ?, sourceId = ? WHERE id = ?",
                               arguments: [result.finalPath, newURL.lastPathComponent, destId, id])
                try AppDatabase.reindexFTS(db, fileId: id)
            } else {
                _ = try FileRecord.deleteOne(db, key: id)
            }
        }
    }

    // MARK: - Protokoll

    func log(limit: Int = 500) throws -> [ActionLogEntry] {
        try db.reader.read { db in
            try ActionLogEntry.order(Column("at").desc).limit(limit).fetchAll(db)
        }
    }

    func undo(_ entry: ActionLogEntry) throws {
        guard let id = entry.id, !entry.undone else { return }
        try FileOps.undo(entry)
        try db.writer.write { db in
            try db.execute(sql: "UPDATE actionLog SET undone = 1 WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE fileVersion SET originalPath = ? WHERE originalPath = ?", arguments: [entry.fromPath, entry.toPath])
        }
        let sources = try db.sources()
        // Beim Zurückverschieben Pfade im Index mitnehmen, damit Tags und Text erhalten bleiben
        if entry.kind == "move", FileManager.default.fileExists(atPath: entry.fromPath) {
            try? updateIndex(from: entry.toPath, to: entry.fromPath, sources: sources)
        }
        indexer.refresh(paths: [entry.fromPath, entry.toPath], sources: sources)
    }

    // MARK: - Versionen

    /// Sichert geänderte Dateien aus Quellen mit aktiver Versionierung in den Versionsordner.
    /// Ist CAWServer aus, wird das beim nächsten Durchlauf nachgeholt.
    @discardableResult
    func snapshotVersions(limit: Int = 20) -> Int {
        let settings = settings()
        guard let folder = settings.versionsFolder, !folder.isEmpty, FileOps.isReachable(folder) else { return 0 }
        let extList = Self.versionableExtensions.map { "'\($0)'" }.joined(separator: ",")
        let candidates: [(FileRecord, String)] = (try? db.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT file.*, source.name AS sourceName FROM file JOIN source ON source.id = file.sourceId
                WHERE source.versioning = 1 AND file.contentHash IS NOT NULL AND file.contentHash != ''
                  AND file.ext IN (\(extList)) AND file.size <= ?
                  AND NOT EXISTS (SELECT 1 FROM fileVersion v WHERE v.originalPath = file.path AND v.contentHash = file.contentHash)
                LIMIT ?
                """, arguments: [Self.maxVersionSize, limit]).map { (try FileRecord(row: $0), $0["sourceName"] as String) }
        }) ?? []

        let fm = FileManager.default
        var count = 0
        for (file, sourceName) in candidates {
            guard fm.fileExists(atPath: file.path), let hash = file.contentHash else { continue }
            let stamp = Self.stampFormatter.string(from: Date())
            let base = file.url.deletingPathExtension().lastPathComponent
            let name = file.ext.isEmpty ? "\(base) \(stamp)" : "\(base) \(stamp).\(file.ext)"
            let dir = URL(fileURLWithPath: folder).appendingPathComponent(sourceName)
                .appendingPathComponent(String(hash.prefix(2)))
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = FileOps.uniqueURL(for: dir.appendingPathComponent(name))
                try fm.copyItem(at: file.url, to: dest)
                try db.writer.write { db in
                    var v = FileVersion(id: nil, originalPath: file.path, at: Date(), contentHash: hash, size: file.size, copyPath: dest.path)
                    try v.insert(db)
                }
                pruneVersions(of: file.path, keep: settings.keepVersions)
                count += 1
            } catch {
                NSLog("DMS Version fehlgeschlagen für \(file.path): \(error)")
            }
        }
        return count
    }

    private func pruneVersions(of path: String, keep: Int) {
        guard let old = try? db.reader.read({ db in
            try FileVersion.filter(Column("originalPath") == path).order(Column("at").desc).fetchAll(db)
        }), old.count > keep else { return }
        for v in old.dropFirst(keep) {
            if let copy = v.copyPath { try? FileManager.default.removeItem(atPath: copy) }
            _ = try? db.writer.write { db in try v.delete(db) }
        }
    }

    func versions(of path: String) throws -> [FileVersion] {
        try db.reader.read { db in
            try FileVersion.filter(Column("originalPath") == path).order(Column("at").desc).fetchAll(db)
        }
    }

    /// Stellt eine Version als Kopie neben dem Original wieder her (das Original bleibt unverändert).
    func restore(_ version: FileVersion) throws -> URL {
        guard let copy = version.copyPath, FileManager.default.fileExists(atPath: copy) else {
            throw FileOps.OpError.sourceMissing(version.copyPath ?? "")
        }
        let original = URL(fileURLWithPath: version.originalPath)
        let base = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        let stamp = Self.stampFormatter.string(from: version.at)
        let name = ext.isEmpty ? "\(base) (Version \(stamp))" : "\(base) (Version \(stamp)).\(ext)"
        let dest = FileOps.uniqueURL(for: original.deletingLastPathComponent().appendingPathComponent(name))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: copy), to: dest)
        return dest
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()
}
