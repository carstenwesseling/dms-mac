import Foundation
import GRDB

/// Einstellungen für Ablage, Nutzungsstufen und Versionen.
struct StorageSettings: Codable, Equatable, Sendable {
    /// Ablageziel für Dateien, die in den letzten `macDays` Tagen genutzt wurden.
    var macTarget: String?
    /// Ablageziel (im Google-Drive-Ordner) für Dateien, die in den letzten `driveDays` Tagen genutzt wurden.
    var driveTarget: String?
    /// Archiv auf CAWServer für alles Ältere.
    var nasTarget: String?
    /// Ordner für Versionen (auf CAWServer).
    var versionsFolder: String?
    var macDays: Int = 60
    var driveDays: Int = 183
    var keepVersions: Int = 10

    static let key = "storage"
}

enum StorageTier: String, Codable, Sendable {
    case mac, drive, nas

    var label: String {
        switch self {
        case .mac: return "Mac"
        case .drive: return "Google Drive"
        case .nas: return "CAWServer"
        }
    }
}

enum RuleField: String, Codable, CaseIterable, Sendable {
    case name, content, ext, tag

    var label: String {
        switch self {
        case .name: return "Dateiname enthält"
        case .content: return "Inhalt enthält"
        case .ext: return "Dateityp ist"
        case .tag: return "hat Tag"
        }
    }
}

/// Regel: Wenn Bedingung, dann Tag setzen und/oder festen Ablageort vorschlagen.
struct Rule: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "rule"

    var id: Int64?
    var name: String
    var enabled: Bool = true
    /// true: wird ohne Rückfrage ausgeführt. false: erzeugt nur Vorschläge.
    var automatic: Bool = false
    var field: RuleField
    var value: String
    var addTag: String?
    var targetPath: String?
    var position: Int = 0

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

enum SuggestionKind: String, Codable, Sendable {
    case move
    case trashDuplicate
    case tag
}

enum SuggestionStatus: String, Codable, Sendable {
    case open, rejected, queued, done, failed

    var label: String {
        switch self {
        case .open: return "offen"
        case .rejected: return "abgelehnt"
        case .queued: return "wartet auf Ziel"
        case .done: return "erledigt"
        case .failed: return "fehlgeschlagen"
        }
    }
}

struct Suggestion: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "suggestion"

    var id: Int64?
    var fileId: Int64
    var kind: SuggestionKind
    var target: String
    var reason: String
    var status: SuggestionStatus
    var detail: String?
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct ActionLogEntry: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "actionLog"

    var id: Int64?
    var at: Date
    var kind: String
    var fromPath: String
    var toPath: String
    var trashPath: String?
    var undone: Bool

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct FileVersion: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "fileVersion"

    var id: Int64?
    var originalPath: String
    var at: Date
    var contentHash: String
    var size: Int64
    var copyPath: String?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Eine Gruppe identischer Dateien.
struct DuplicateGroup: Identifiable, Sendable {
    var hash: String
    var files: [FileRow]
    var id: String { hash }
    var wastedBytes: Int64 { (files.first?.file.size ?? 0) * Int64(max(files.count - 1, 0)) }
}

/// Ein Vorschlag mit Datei-Infos für die Anzeige.
struct SuggestionRow: Identifiable, Hashable, Sendable {
    var suggestion: Suggestion
    var file: FileRecord
    var id: Int64 { suggestion.id ?? -1 }
}
