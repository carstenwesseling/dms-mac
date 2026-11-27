import Foundation
import GRDB

/// Zugriff auf den lokalen Index (SQLite).
/// Die Datenbank liegt unter ~/Library/Application Support/DMS/dms.sqlite.
final class AppDatabase: @unchecked Sendable {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    var reader: any DatabaseReader { writer }

    static func openShared() throws -> AppDatabase {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("DMS", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("dms.sqlite").path, configuration: config)
        return try AppDatabase(pool)
    }

    static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "source") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("remoteURL", .text)
                t.column("lastScan", .datetime)
            }

            try db.create(table: "file") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceId", .integer).notNull().indexed()
                    .references("source", onDelete: .cascade)
                t.column("path", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("ext", .text).notNull().indexed()
                t.column("typeIdentifier", .text)
                t.column("size", .integer).notNull()
                t.column("modified", .datetime).notNull()
                t.column("created", .datetime)
                t.column("lastUsed", .datetime)
                t.column("contentHash", .text).indexed()
                t.column("textState", .text).notNull().defaults(to: TextState.pending.rawValue).indexed()
                t.column("scanMark", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "content") { t in
                t.primaryKey("fileId", .integer).references("file", onDelete: .cascade)
                t.column("body", .text).notNull()
                t.column("method", .text).notNull()   // z. B. pdf, ocr, docx
            }

            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique().collate(.nocase)
            }

            try db.create(table: "fileTag") { t in
                t.column("fileId", .integer).notNull().references("file", onDelete: .cascade)
                t.column("tagId", .integer).notNull().indexed().references("tag", onDelete: .cascade)
                t.primaryKey(["fileId", "tagId"])
            }

            try db.create(table: "usage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fileId", .integer).notNull().indexed().references("file", onDelete: .cascade)
                t.column("at", .datetime).notNull()
                t.column("kind", .text).notNull()     // opened, revealed
            }

            // Volltextindex über Name, Inhalt und Tags. rowid = file.id
            try db.create(virtualTable: "file_fts", using: FTS5()) { t in
                t.tokenizer = .unicode61()
                t.column("name")
                t.column("body")
                t.column("tags")
            }

            try db.execute(sql: """
                CREATE TRIGGER file_fts_delete AFTER DELETE ON file BEGIN
                    DELETE FROM file_fts WHERE rowid = old.id;
                END;
                """)
        }

        migrator.registerMigration("v2-ablage") { db in
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }

            try db.alter(table: "source") { t in
                t.add(column: "versioning", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "rule") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("automatic", .boolean).notNull().defaults(to: false)
                t.column("field", .text).notNull()       // name, content, ext, tag
                t.column("value", .text).notNull()
                t.column("addTag", .text)
                t.column("targetPath", .text)
                t.column("position", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "suggestion") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fileId", .integer).notNull().indexed().references("file", onDelete: .cascade)
                t.column("kind", .text).notNull()        // move, trashDuplicate, tag
                t.column("target", .text).notNull()      // Zielpfad oder Tag-Name
                t.column("reason", .text).notNull()
                t.column("status", .text).notNull().indexed()   // open, rejected, queued, done, failed
                t.column("detail", .text)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["fileId", "kind", "target"])
            }

            try db.create(table: "actionLog") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("at", .datetime).notNull()
                t.column("kind", .text).notNull()        // move, trash
                t.column("fromPath", .text).notNull()
                t.column("toPath", .text).notNull()
                t.column("trashPath", .text)             // Original im Papierkorb (für Rückgängig)
                t.column("undone", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "fileVersion") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("originalPath", .text).notNull().indexed()
                t.column("at", .datetime).notNull()
                t.column("contentHash", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("copyPath", .text)              // nil = wartet auf NAS
            }
        }

        migrator.registerMigration("v3-ki") { db in
            // Ergebnisse der lokalen KI: Zusammenfassung und erkannte Bildinhalte
            try db.create(table: "analysis") { t in
                t.primaryKey("fileId", .integer).references("file", onDelete: .cascade)
                t.column("summary", .text)
                t.column("labels", .text)
                t.column("model", .text).notNull()
                t.column("at", .datetime).notNull()
            }
        }

        migrator.registerMigration("v4-ki-nur-dokumente") { db in
            // Frühere KI-Vorschläge für Code- und Konfigurationsdateien entfernen
            let docs = Analyzer.documentList
            try db.execute(sql: """
                DELETE FROM suggestion WHERE status = 'open' AND reason = 'KI-Vorschlag'
                  AND fileId IN (SELECT id FROM file WHERE ext NOT IN (\(docs)))
                """)
            try db.execute(sql: "DELETE FROM analysis WHERE labels IS NULL AND fileId IN (SELECT id FROM file WHERE ext NOT IN (\(docs)))")
        }

        migrator.registerMigration("v5-konkrete-bildtags") { db in
            // Grobe Bildkategorien nicht mehr als Tags vorschlagen
            try db.execute(sql: "DELETE FROM suggestion WHERE status = 'open' AND reason = 'Bilderkennung'")
        }

        return migrator
    }
}

// MARK: - Volltext

extension AppDatabase {
    /// Baut den Suchindex-Eintrag einer Datei neu auf (Name, Inhalt, Tags).
    static func reindexFTS(_ db: Database, fileId: Int64) throws {
        guard let file = try FileRecord.fetchOne(db, key: fileId) else { return }
        let body = try String.fetchOne(db, sql: "SELECT body FROM content WHERE fileId = ?", arguments: [fileId]) ?? ""
        let tags = try String.fetchAll(db, sql: """
            SELECT tag.name FROM tag JOIN fileTag ON fileTag.tagId = tag.id WHERE fileTag.fileId = ?
            """, arguments: [fileId]).joined(separator: " ")
        // Dateiname zusätzlich ohne Trennzeichen, damit "Rechnung_2024" auch bei "Rechnung" gefunden wird
        let nameWords = file.name.replacingOccurrences(of: "[_\\-.]", with: " ", options: .regularExpression)
        try db.execute(sql: "DELETE FROM file_fts WHERE rowid = ?", arguments: [fileId])
        try db.execute(sql: "INSERT INTO file_fts(rowid, name, body, tags) VALUES (?, ?, ?, ?)",
                       arguments: [fileId, nameWords, body, tags])
    }

    /// Volltextsuche. Leere Suche liefert die zuletzt geänderten Dateien.
    func search(_ text: String, sourceId: Int64? = nil, tagId: Int64? = nil, category: FileCategory? = nil, limit: Int = 500) throws -> [FileRow] {
        try reader.read { db in
            var conditions: [String] = []
            var args: [(any DatabaseValueConvertible)?] = []

            if let sourceId {
                conditions.append("file.sourceId = ?")
                args.append(sourceId)
            }
            if let tagId {
                conditions.append("file.id IN (SELECT fileId FROM fileTag WHERE tagId = ?)")
                args.append(tagId)
            }
            if let category {
                let exts = Self.extensions(of: category, in: db)
                if !exts.isEmpty {
                    conditions.append("file.ext IN (\(exts.map { _ in "?" }.joined(separator: ",")))")
                    args.append(contentsOf: exts)
                }
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let sql: String
            if let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed), !trimmed.isEmpty {
                var where_ = ["file_fts MATCH ?"]
                where_.append(contentsOf: conditions)
                sql = """
                    SELECT file.*, source.name AS sourceName,
                           snippet(file_fts, 1, '»', '«', '…', 14) AS snippet
                    FROM file_fts
                    JOIN file ON file.id = file_fts.rowid
                    JOIN source ON source.id = file.sourceId
                    WHERE \(where_.joined(separator: " AND "))
                    ORDER BY bm25(file_fts, 10.0, 1.0, 5.0)
                    LIMIT \(limit)
                    """
                args.insert(pattern, at: 0)
            } else {
                let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
                sql = """
                    SELECT file.*, source.name AS sourceName, NULL AS snippet
                    FROM file JOIN source ON source.id = file.sourceId
                    \(whereClause)
                    ORDER BY file.modified DESC
                    LIMIT \(limit)
                    """
            }

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return try rows.map { row in
                FileRow(file: try FileRecord(row: row),
                        sourceName: row["sourceName"],
                        snippet: Self.cleanSnippet(row["snippet"]))
            }
        }
    }

    private static func extensions(of category: FileCategory, in db: Database) -> [String] {
        let all = (try? String.fetchAll(db, sql: "SELECT DISTINCT ext FROM file")) ?? []
        return all.filter { FileCategory(ext: $0) == category }
    }

    private static func cleanSnippet(_ s: String?) -> String? {
        guard let s, s.contains("»") else { return nil }
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

// MARK: - Tags

extension AppDatabase {
    func allTags() throws -> [Tag] {
        try reader.read { db in try Tag.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db) }
    }

    func tags(forFile fileId: Int64) throws -> [Tag] {
        try reader.read { db in
            try Tag.fetchAll(db, sql: """
                SELECT tag.* FROM tag JOIN fileTag ON fileTag.tagId = tag.id
                WHERE fileTag.fileId = ? ORDER BY tag.name
                """, arguments: [fileId])
        }
    }

    /// Legt einen Tag an (falls neu) und gibt seine ID zurück.
    static func tagId(_ db: Database, name: String) throws -> Int64 {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE name = ? COLLATE NOCASE", arguments: [clean]) {
            return existing
        }
        var tag = Tag(id: nil, name: clean)
        try tag.insert(db)
        return tag.id!
    }

    func addTag(_ name: String, to fileIds: [Int64]) throws {
        try writer.write { db in
            let tagId = try Self.tagId(db, name: name)
            for fileId in fileIds {
                try db.execute(sql: "INSERT OR IGNORE INTO fileTag(fileId, tagId) VALUES (?, ?)", arguments: [fileId, tagId])
                try Self.reindexFTS(db, fileId: fileId)
            }
        }
    }

    func removeTag(_ tagId: Int64, from fileIds: [Int64]) throws {
        try writer.write { db in
            for fileId in fileIds {
                try db.execute(sql: "DELETE FROM fileTag WHERE fileId = ? AND tagId = ?", arguments: [fileId, tagId])
                try Self.reindexFTS(db, fileId: fileId)
            }
            // Tags ohne Dateien aufräumen
            try db.execute(sql: "DELETE FROM tag WHERE id NOT IN (SELECT tagId FROM fileTag)")
        }
    }
}

// MARK: - Nutzung

extension AppDatabase {
    func recordUsage(fileId: Int64, kind: String) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO usage(fileId, at, kind) VALUES (?, ?, ?)", arguments: [fileId, Date(), kind])
            try db.execute(sql: "UPDATE file SET lastUsed = ? WHERE id = ?", arguments: [Date(), fileId])
        }
    }
}

// MARK: - Statistik fürs Dashboard

struct SourceStats: Identifiable, Sendable {
    var source: Source
    var fileCount: Int
    var indexedBytes: Int64
    var volumeTotal: Int64?
    var volumeFree: Int64?
    var id: Int64 { source.id ?? -1 }
}

struct CategoryStats: Identifiable, Sendable {
    var category: FileCategory
    var fileCount: Int
    var bytes: Int64
    var id: String { category.rawValue }
}

struct IndexProgress: Sendable {
    var total: Int
    var pending: Int
    var withText: Int
}

extension AppDatabase {
    func sources() throws -> [Source] {
        try reader.read { db in try Source.order(Column("name")).fetchAll(db) }
    }

    func sourceStats() throws -> [SourceStats] {
        let rows: [(Source, Int, Int64)] = try reader.read { db in
            try Source.order(Column("name")).fetchAll(db).map { source in
                let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS bytes FROM file WHERE sourceId = ?", arguments: [source.id])
                return (source, row?["n"] ?? 0, row?["bytes"] ?? 0)
            }
        }
        return rows.map { source, count, bytes in
            var stats = SourceStats(source: source, fileCount: count, indexedBytes: bytes)
            if source.isReachable,
               let values = try? source.url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) {
                stats.volumeTotal = values.volumeTotalCapacity.map(Int64.init)
                stats.volumeFree = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
            }
            return stats
        }
    }

    func categoryStats() throws -> [CategoryStats] {
        let rows = try reader.read { db in
            try Row.fetchAll(db, sql: "SELECT ext, COUNT(*) AS n, COALESCE(SUM(size), 0) AS bytes FROM file GROUP BY ext")
        }
        var byCategory: [FileCategory: CategoryStats] = [:]
        for row in rows {
            let category = FileCategory(ext: row["ext"])
            var entry = byCategory[category] ?? CategoryStats(category: category, fileCount: 0, bytes: 0)
            entry.fileCount += row["n"] as Int
            entry.bytes += row["bytes"] as Int64
            byCategory[category] = entry
        }
        return byCategory.values.sorted { $0.bytes > $1.bytes }
    }

    func extensionCounts() throws -> [(ext: String, count: Int)] {
        try reader.read { db in
            try Row.fetchAll(db, sql: "SELECT ext, COUNT(*) AS n FROM file WHERE ext != '' GROUP BY ext ORDER BY n DESC")
                .map { (ext: $0["ext"], count: $0["n"]) }
        }
    }

    func progress() throws -> IndexProgress {
        try reader.read { db in
            IndexProgress(
                total: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file") ?? 0,
                pending: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file WHERE textState = 'pending'") ?? 0,
                withText: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file WHERE textState = 'done'") ?? 0
            )
        }
    }
}
