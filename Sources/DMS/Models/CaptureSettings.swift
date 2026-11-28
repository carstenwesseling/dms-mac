import Foundation

/// Welche Dateitypen bei der Datenerfassung gelesen werden (Text, Texterkennung).
/// Abgeschaltete Typen bleiben im Index und sind über Name und Ordner auffindbar, ihr Inhalt wird aber nicht gelesen.
enum CaptureSettings {
    /// Typen, aus denen überhaupt Text gelesen werden kann
    static let categories: [FileCategory] = [.dokumente, .tabellen, .praesentationen, .bilder, .code, .sonstige]

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
        default: return category.rawValue
        }
    }

    private static func key(_ category: FileCategory) -> String { "capture.off." + category.rawValue }
}
