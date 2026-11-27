import Foundation
import GRDB

/// Stand der Datenerfassung (Text, Prüfsummen) und des Taggings (lokale KI) für die Einstellungen.
struct ProcessingStats: Sendable, Equatable {
    var total = 0
    var textPending = 0
    var textFailed = 0
    var hashFailed = 0
    var imagesPending = 0
    var imagesTagged = 0
    var docsPending = 0
    var docsDone = 0
    var aiFailed = 0
}

extension AppDatabase {
    func processingStats() throws -> ProcessingStats {
        let images = TextExtractor.imageExtensions.map { "'\($0)'" }.joined(separator: ",")
        let docs = Analyzer.documentList
        return try reader.read { db in
            func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? 0 }
            var s = ProcessingStats()
            s.total = try count("SELECT COUNT(*) FROM file")
            s.textPending = try count("SELECT COUNT(*) FROM file WHERE textState = 'pending'")
            s.textFailed = try count("SELECT COUNT(*) FROM file WHERE textState = 'failed'")
            s.hashFailed = try count("SELECT COUNT(*) FROM file WHERE contentHash = ''")
            s.imagesPending = try count("""
                SELECT COUNT(*) FROM file WHERE ext IN (\(images))
                  AND (NOT EXISTS (SELECT 1 FROM analysis a WHERE a.fileId = file.id)
                       OR EXISTS (SELECT 1 FROM analysis a WHERE a.fileId = file.id AND a.model = 'vision'))
                """)
            s.imagesTagged = try count("""
                SELECT COUNT(*) FROM file JOIN analysis a ON a.fileId = file.id
                WHERE file.ext IN (\(images)) AND a.model NOT IN ('vision', 'fehler')
                """)
            s.docsPending = try count("""
                SELECT COUNT(*) FROM file WHERE textState = 'done' AND ext IN (\(docs))
                  AND NOT EXISTS (SELECT 1 FROM analysis a WHERE a.fileId = file.id)
                """)
            s.docsDone = try count("SELECT COUNT(*) FROM analysis WHERE summary IS NOT NULL")
            s.aiFailed = try count("SELECT COUNT(*) FROM analysis WHERE model = 'fehler'")
            return s
        }
    }

    /// Setzt Dateien, bei denen Text oder Prüfsumme nicht ermittelt werden konnte, wieder auf „offen“.
    /// Gibt die Anzahl der zurückgesetzten Dateien zurück.
    @discardableResult
    func resetFailedCapture() throws -> Int {
        try writer.write { db in
            try db.execute(sql: "UPDATE file SET textState = 'pending' WHERE textState = 'failed'")
            var n = db.changesCount
            try db.execute(sql: "UPDATE file SET contentHash = NULL WHERE contentHash = ''")
            n += db.changesCount
            return n
        }
    }

    /// Fehlgeschlagene KI-Auswertungen und Bilder ohne erkannte Inhalte erneut in die Warteschlange stellen.
    /// Bereits vergebene Tags und fertige Zusammenfassungen bleiben erhalten.
    @discardableResult
    func resetFailedTagging() throws -> Int {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM analysis WHERE model = 'fehler'")
            var n = db.changesCount
            try db.execute(sql: "DELETE FROM analysis WHERE model = 'vision' AND COALESCE(labels, '') = ''")
            n += db.changesCount
            return n
        }
    }
}
