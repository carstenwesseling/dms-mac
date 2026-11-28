import Foundation

/// Welche Dateitypen bei der Datenerfassung gelesen werden (Text, Texterkennung).
/// Abgeschaltete Typen bleiben im Index und sind über Name und Ordner auffindbar, ihr Inhalt wird aber nicht gelesen.
enum CaptureSettings {
    /// Typen, aus denen überhaupt Text gelesen werden kann
    static let categories: [FileCategory] = [.dokumente, .tabellen, .praesentationen, .bilder, .code, .sonstige]
    /// Typen ohne Text, die nur für die Dublettensuche ganz gelesen werden (Prüfsumme)
    static let mediaCategories: [FileCategory] = [.videos, .audio, .archive]

    static let mediaExtensions: [FileCategory: [String]] = [
        .videos: ["mov", "mp4", "m4v", "avi", "mkv", "wmv"],
        .audio: ["mp3", "m4a", "wav", "aiff", "flac", "aac"],
        .archive: ["zip", "rar", "7z", "tar", "gz", "dmg", "iso"],
    ]

    /// Endungen, deren Prüfsumme nicht berechnet werden soll (abgeschaltete Medientypen)
    static var excludedFromHashing: [String] {
        mediaCategories.filter { !isEnabled($0) }.flatMap { mediaExtensions[$0] ?? [] }
    }

    static func isEnabled(_ category: FileCategory) -> Bool {
        !UserDefaults.standard.bool(forKey: key(category))
    }

    static func setEnabled(_ category: FileCategory, _ enabled: Bool) {
        UserDefaults.standard.set(!enabled, forKey: key(category))
    }

    static func isEnabled(ext: String) -> Bool {
        isEnabled(FileCategory(ext: ext))
    }

    /// Lesbare Endungen eines Typs, z. B. für Bilder jpg, png, heic …
    static func extensions(of category: FileCategory) -> [String] {
        TextExtractor.supportedExtensions.filter { FileCategory(ext: $0) == category }.sorted()
    }

    static func label(_ category: FileCategory) -> String {
        switch category {
        case .bilder: return "Bilder und Fotos (Texterkennung)"
        case .code: return "Code"
        case .sonstige: return "Sonstige Textdateien (z. B. ini, log)"
        case .videos: return "Videos"
        case .audio: return "Musik und Audio"
        case .archive: return "Archive (zip, dmg …)"
        default: return category.rawValue
        }
    }

    private static func key(_ category: FileCategory) -> String { "capture.off." + category.rawValue }
}
