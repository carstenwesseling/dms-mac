import Foundation
import GRDB

/// Art eines eingebundenen Speicherorts.
enum SourceKind: String, Codable, CaseIterable, Sendable {
    case local
    case nas
    case googleDrive

    var label: String {
        switch self {
        case .local: return "Mac"
        case .nas: return "NAS"
        case .googleDrive: return "Google Drive"
        }
    }

    var systemImage: String {
        switch self {
        case .local: return "internaldrive"
        case .nas: return "server.rack"
        case .googleDrive: return "icloud"
        }
    }
}

/// Ein eingebundener Ordner (Mac, NAS-Freigabe oder Google-Drive-Ordner).
struct Source: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "source"

    var id: Int64?
    var name: String
    var kind: SourceKind
    /// Lokaler Pfad, z. B. /Volumes/CAWServer/Daten
    var path: String
    /// Adresse zum erneuten Verbinden, z. B. smb://CAWServer/Daten
    var remoteURL: String?
    var lastScan: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    var isReachable: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Zustand der Textauswertung einer Datei.
enum TextState: String, Codable, Sendable {
    case pending      // noch nicht ausgewertet
    case done         // Text vorhanden
    case empty        // ausgewertet, kein Text gefunden
    case skipped      // Dateityp wird nicht ausgewertet
    case cloudOnly    // liegt nur online (Google Drive), wird nicht heruntergeladen
    case failed       // Fehler beim Lesen
}

/// Eine indexierte Datei.
struct FileRecord: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "file"

    var id: Int64?
    var sourceId: Int64
    var path: String
    var name: String
    var ext: String
    var typeIdentifier: String?
    var size: Int64
    var modified: Date
    var created: Date?
    var lastUsed: Date?
    var contentHash: String?
    var textState: TextState
    var scanMark: Int64

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var url: URL { URL(fileURLWithPath: path) }
    var category: FileCategory { FileCategory(ext: ext) }
}

struct Tag: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "tag"

    var id: Int64?
    var name: String

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Grobe Einteilung der Dateitypen für Dashboard und Filter.
enum FileCategory: String, CaseIterable, Sendable {
    case dokumente = "Dokumente"
    case tabellen = "Tabellen"
    case praesentationen = "Präsentationen"
    case bilder = "Bilder"
    case videos = "Videos"
    case audio = "Audio"
    case code = "Code"
    case archive = "Archive"
    case sonstige = "Sonstige"

    init(ext: String) {
        switch ext.lowercased() {
        case "pdf", "doc", "docx", "txt", "rtf", "rtfd", "pages", "md", "odt", "epub":
            self = .dokumente
        case "xls", "xlsx", "csv", "numbers", "ods", "tsv":
            self = .tabellen
        case "ppt", "pptx", "key", "odp":
            self = .praesentationen
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "raw", "cr2", "nef", "arw", "dng", "svg":
            self = .bilder
        case "mov", "mp4", "m4v", "avi", "mkv", "wmv":
            self = .videos
        case "mp3", "m4a", "wav", "aiff", "flac", "aac":
            self = .audio
        case "swift", "py", "js", "ts", "java", "c", "h", "cpp", "m", "rb", "go", "rs", "sh", "json", "xml", "yaml", "yml", "html", "css", "sql", "php", "kt":
            self = .code
        case "zip", "rar", "7z", "tar", "gz", "dmg", "iso":
            self = .archive
        default:
            self = .sonstige
        }
    }
}

/// Eine Zeile in der Dateiliste (Datei plus Anzeige-Infos).
struct FileRow: Identifiable, Hashable, Sendable {
    var file: FileRecord
    var sourceName: String
    var snippet: String?

    var id: Int64 { file.id ?? -1 }
}
