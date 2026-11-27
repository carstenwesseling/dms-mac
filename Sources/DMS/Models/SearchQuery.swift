import Foundation

/// Zerlegt die Eingabe im Suchfeld in Suchtext und gezielte Filter.
///
/// Beispiele:
/// - `typ:pdf rechnung` sucht „rechnung“ nur in PDF-Dateien
/// - `typ:bilder quelle:cawserver` zeigt alle Bilder auf CAWServer
/// - `quelle:"Google Drive" vertrag` – Namen mit Leerzeichen in Anführungszeichen
struct SearchQuery: Equatable, Sendable {
    var text: String = ""
    var ext: String?
    var category: FileCategory?
    /// Name (oder Anfang des Namens) einer Quelle
    var sourceName: String?

    private static let typeKeys: Set<String> = ["typ", "type", "art", "endung"]
    private static let sourceKeys: Set<String> = ["quelle", "source", "ort"]

    init(text: String = "", ext: String? = nil, category: FileCategory? = nil, sourceName: String? = nil) {
        self.text = text
        self.ext = ext
        self.category = category
        self.sourceName = sourceName
    }

    init(parsing input: String) {
        var words: [String] = []
        for token in Self.tokens(input) {
            guard let colon = token.firstIndex(of: ":") else { words.append(token); continue }
            let key = token[..<colon].lowercased()
            let value = String(token[token.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"."))
            if value.isEmpty { words.append(token); continue }
            if Self.typeKeys.contains(key) {
                if let cat = Self.category(named: value) { category = cat } else { ext = value.lowercased() }
            } else if Self.sourceKeys.contains(key) {
                sourceName = value
            } else {
                words.append(token)
            }
        }
        text = words.joined(separator: " ")
    }

    /// Kategorie nach Namen, auch Einzahl und ohne Umlaute („bild“, „praesentation“, „tabelle“).
    static func category(named name: String) -> FileCategory? {
        let n = name.lowercased()
            .replacingOccurrences(of: "ä", with: "ae")
            .replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ü", with: "ue")
        guard n.count >= 3 else { return nil }
        return FileCategory.allCases.first { cat in
            let full = cat.rawValue.lowercased().replacingOccurrences(of: "ä", with: "ae")
            return full == n || full.hasPrefix(n) && n.count >= 4
        }
    }

    /// Wörter trennen, Anführungszeichen halten Leerzeichen zusammen.
    private static func tokens(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for ch in input {
            if ch == "\"" { quoted.toggle(); current.append(ch); continue }
            if ch.isWhitespace && !quoted {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
