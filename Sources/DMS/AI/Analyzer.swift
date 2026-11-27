import Foundation
import GRDB
import Vision

/// Lokale KI: Bildinhalte erkennen, Dokumente zusammenfassen, Tags und Ordnerstruktur vorschlagen.
/// Tags werden nur vorgeschlagen (Ablagevorschläge), nie ungefragt gesetzt.
final class Analyzer: @unchecked Sendable {
    let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    struct Analysis: Sendable {
        var summary: String?
        var labels: [String]
        var model: String
        var at: Date
    }

    // MARK: - Einstellungen

    func settings() -> AISettings {
        let json = try? db.reader.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [AISettings.key])
        }
        guard let json, let decoded = try? JSONDecoder().decode(AISettings.self, from: Data(json.utf8)) else { return AISettings() }
        return decoded
    }

    func save(_ settings: AISettings) throws {
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        try db.writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO setting(key, value) VALUES (?, ?)", arguments: [AISettings.key, json])
        }
    }

    func analysis(fileId: Int64) -> Analysis? {
        try? db.reader.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM analysis WHERE fileId = ?", arguments: [fileId]) else { return nil }
            let labels = (row["labels"] as String?)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            return Analysis(summary: row["summary"], labels: labels, model: row["model"], at: row["at"])
        }
    }

    func counts() -> (summaries: Int, pendingDocs: Int, images: Int) {
        return (try? db.reader.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM analysis WHERE summary IS NOT NULL") ?? 0,
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM file WHERE textState = 'done' AND ext IN (\(Self.documentList))
                      AND NOT EXISTS (SELECT 1 FROM analysis a WHERE a.fileId = file.id)
                    """) ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM analysis WHERE labels IS NOT NULL") ?? 0
            )
        }) ?? (0, 0, 0)
    }

    // MARK: - Bilder (Apple Vision)

    /// Erkennt Bildinhalte, macht sie durchsuchbar und schlägt die deutlichsten als Tags vor.
    func tagImages(limit: Int = 10) -> Int {
        guard let reachable = try? db.sources().filter(\.isReachable).compactMap(\.id), !reachable.isEmpty else { return 0 }
        let imageList = TextExtractor.imageExtensions.map { "'\($0)'" }.joined(separator: ",")
        let files: [FileRecord] = (try? db.reader.read { db in
            try FileRecord.fetchAll(db, sql: """
                SELECT * FROM file WHERE ext IN (\(imageList)) AND textState IN ('done', 'empty')
                  AND sourceId IN (\(reachable.map(String.init).joined(separator: ",")))
                  AND NOT EXISTS (SELECT 1 FROM analysis a WHERE a.fileId = file.id)
                ORDER BY modified DESC LIMIT ?
                """, arguments: [limit])
        }) ?? []

        for file in files {
            guard let id = file.id else { continue }
            let labels = (try? autoreleasepool { try Self.classify(file.url) }) ?? []
            let names = labels.map(\.name)
            try? db.writer.write { db in
                try db.execute(sql: "INSERT OR REPLACE INTO analysis(fileId, summary, labels, model, at) VALUES (?, NULL, ?, 'vision', ?)",
                               arguments: [id, names.joined(separator: ", "), Date()])
                if !names.isEmpty {
                    let extra = "Bildinhalt: " + names.joined(separator: ", ")
                    if let body = try String.fetchOne(db, sql: "SELECT body FROM content WHERE fileId = ?", arguments: [id]) {
                        try db.execute(sql: "UPDATE content SET body = ? WHERE fileId = ?", arguments: [body + "\n" + extra, id])
                    } else {
                        try db.execute(sql: "INSERT INTO content(fileId, body, method) VALUES (?, ?, 'vision')", arguments: [id, extra])
                    }
                    try AppDatabase.reindexFTS(db, fileId: id)
                }
                for label in labels.prefix(3) where label.confidence >= 0.5 {
                    try Self.suggestTag(db, fileId: id, tag: label.name, reason: "Bilderkennung")
                }
            }
        }
        return files.count
    }

    struct Label { var name: String; var confidence: Float }

    static func classify(_ url: URL) throws -> [Label] {
        guard let image = TextExtractor.loadImage(url, maxPixel: 1024) else { return [] }
        let request = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let ignored: Set<String> = ["structure", "material", "conveyance", "consumable", "liquid", "container", "object"]
        return (request.results ?? [])
            .filter { $0.confidence >= 0.3 && !ignored.contains($0.identifier) }
            .prefix(6)
            .map { Label(name: ImageLabels.german($0.identifier), confidence: $0.confidence) }
    }

    // MARK: - Dokumente (Sprachmodell)

    /// Nur echte Dokumente werden zusammengefasst, kein Code und keine Konfigurationsdateien.
    static let documentExtensions = ["pdf", "doc", "docx", "rtf", "rtfd", "odt", "txt", "md", "xlsx", "pptx", "pages", "numbers", "key"]
    static var documentList: String { documentExtensions.map { "'\($0)'" }.joined(separator: ",") }

    static let systemPrompt = "Du bist ein Assistent für die Verwaltung persönlicher Dokumente. Antworte immer auf Deutsch, knapp und genau im verlangten Format."

    /// Fasst bis zu `limit` Dokumente zusammen. Ohne verfügbares Modell passiert nichts.
    func summarizePending(limit: Int = 1) async -> Int {
        let settings = settings()
        guard settings.enabled, let model = await LocalModel.find(settings: settings) else { return 0 }
        let files: [FileRecord] = (try? await db.reader.read { db in
            try FileRecord.fetchAll(db, sql: """
                SELECT * FROM file WHERE textState = 'done' AND ext IN (\(Self.documentList))
                  AND NOT EXISTS (SELECT 1 FROM analysis a WHERE a.fileId = file.id)
                ORDER BY modified DESC LIMIT ?
                """, arguments: [limit])
        }) ?? []
        var done = 0
        for file in files {
            do {
                try await summarize(file, with: model)
                done += 1
            } catch {
                NSLog("DMS KI-Fehler bei \(file.name): \(error)")
                // Fehler merken, damit die Datei nicht endlos neu versucht wird
                if let id = file.id {
                    try? await db.writer.write { db in
                        try db.execute(sql: "INSERT OR REPLACE INTO analysis(fileId, summary, labels, model, at) VALUES (?, NULL, NULL, ?, ?)",
                                       arguments: [id, "fehler", Date()])
                    }
                }
            }
        }
        return done
    }

    /// Erstellt die Zusammenfassung einer Datei (auch auf Knopfdruck aus der Detailansicht).
    func summarize(_ file: FileRecord, with given: LocalModel? = nil) async throws {
        guard let id = file.id else { return }
        let found: LocalModel?
        if let given { found = given } else { found = await LocalModel.find(settings: settings()) }
        guard let model = found else { throw LocalModelError.unavailable }
        let text = try await db.reader.read { db in
            try String.fetchOne(db, sql: "SELECT body FROM content WHERE fileId = ?", arguments: [id]) ?? ""
        }
        guard !text.isEmpty else { return }

        let prompt = """
            Dateiname: \(file.name)

            Inhalt:
            \(text.prefix(6000))

            Aufgabe: Fasse den Inhalt in 2 bis 3 Sätzen zusammen. Nenne danach 3 bis 5 kurze Schlagwörter, \
            die sich als Ordner-Tags eignen (z. B. Rechnung, Versicherung, Steuer 2024, Auto).
            Antworte genau in diesem Format:
            ZUSAMMENFASSUNG: <Text>
            SCHLAGWÖRTER: <Wort>, <Wort>, <Wort>
            """
        let answer = try await model.complete(system: Self.systemPrompt, prompt: prompt)
        let parsed = Self.parse(answer)
        try await db.writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO analysis(fileId, summary, labels, model, at) VALUES (?, ?, NULL, ?, ?)",
                           arguments: [id, parsed.summary, model.name, Date()])
            for tag in parsed.tags.prefix(5) {
                try Self.suggestTag(db, fileId: id, tag: tag, reason: "KI-Vorschlag")
            }
        }
    }

    /// Liest Zusammenfassung und Schlagwörter aus der Modellantwort.
    static func parse(_ answer: String) -> (summary: String, tags: [String]) {
        let clean = answer.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        var summaryLines: [String] = []
        var tags: [String] = []
        var inSummary = false
        for raw in clean.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
            let upper = line.uppercased()
            if upper.hasPrefix("ZUSAMMENFASSUNG:") {
                inSummary = true
                summaryLines.append(String(line.dropFirst("ZUSAMMENFASSUNG:".count)).trimmingCharacters(in: .whitespaces))
            } else if upper.hasPrefix("SCHLAGWÖRTER:") || upper.hasPrefix("SCHLAGWORTE:") || upper.hasPrefix("TAGS:") {
                inSummary = false
                let value = line.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                tags = value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .#\"'")) }
                    .filter { !$0.isEmpty && $0.count <= 30 }
            } else if inSummary, !line.isEmpty {
                summaryLines.append(line)
            }
        }
        var summary = summaryLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if summary.isEmpty { summary = clean.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (summary, tags)
    }

    static func suggestTag(_ db: Database, fileId: Int64, tag: String, reason: String) throws {
        let has = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM fileTag JOIN tag ON tag.id = fileTag.tagId
                          WHERE fileTag.fileId = ? AND tag.name = ? COLLATE NOCASE)
            """, arguments: [fileId, tag]) ?? false
        guard !has else { return }
        try db.execute(sql: """
            INSERT OR IGNORE INTO suggestion(fileId, kind, target, reason, status, createdAt)
            VALUES (?, 'tag', ?, ?, 'open', ?)
            """, arguments: [fileId, tag, reason, Date()])
    }

    // MARK: - Ordnerstruktur

    /// Schlägt anhand der vorhandenen Ordner eine flache Struktur nach Lebensbereich und Jahr vor.
    func suggestStructure() async throws -> String {
        guard let model = await LocalModel.find(settings: settings()) else { throw LocalModelError.unavailable }
        let sources = try db.sources()
        let paths = try await db.reader.read { db in try String.fetchAll(db, sql: "SELECT path FROM file") }
        var counts: [String: Int] = [:]
        for path in paths {
            guard let source = sources.first(where: { $0.contains(path) }) else { continue }
            let relative = path.dropFirst(source.path.count).split(separator: "/")
            let folder = relative.count > 1 ? "\(source.name)/\(relative[0])" + (relative.count > 2 ? "/\(relative[1])" : "") : source.name
            counts[folder, default: 0] += 1
        }
        let list = counts.sorted { $0.value > $1.value }.prefix(60)
            .map { "- \($0.key) (\($0.value) Dateien)" }.joined(separator: "\n")
        let prompt = """
            Hier sind die vorhandenen Ordner meiner persönlichen Ablage mit der Anzahl Dateien:
            \(list)

            Schlage eine flache, übersichtliche Ordnerstruktur nach Lebensbereich und Jahr vor \
            (höchstens 12 Bereiche, z. B. Finanzen/2026, Wohnen, Arbeit/Projekte, Fotos/2025).
            Gib zuerst die neue Struktur als Liste an. Ordne danach jeden vorhandenen Ordner einem Bereich zu, \
            im Format "alter Ordner → neuer Bereich". Antworte auf Deutsch.
            """
        let answer = try await model.complete(system: Self.systemPrompt, prompt: prompt)
        return answer.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Deutsche Namen für häufige Bildklassen von Apple Vision.
enum ImageLabels {
    static let names: [String: String] = [
        "people": "Menschen", "person": "Person", "adult": "Erwachsene", "child": "Kind", "baby": "Baby", "portrait": "Porträt",
        "selfie": "Selfie", "crowd": "Menschenmenge", "wedding": "Hochzeit", "party": "Feier", "birthday": "Geburtstag",
        "animal": "Tier", "dog": "Hund", "cat": "Katze", "bird": "Vogel", "horse": "Pferd", "pet": "Haustier",
        "outdoor": "Draußen", "indoor": "Drinnen", "sky": "Himmel", "cloudy": "Wolken", "sunset_sunrise": "Sonnenuntergang",
        "beach": "Strand", "sea": "Meer", "ocean": "Meer", "lake": "See", "river": "Fluss", "water": "Wasser",
        "mountain": "Berge", "hill": "Hügel", "forest": "Wald", "tree": "Baum", "plant": "Pflanze", "flower": "Blume",
        "garden": "Garten", "grass": "Wiese", "snow": "Schnee", "winter": "Winter", "landscape": "Landschaft",
        "city": "Stadt", "street": "Straße", "building": "Gebäude", "house": "Haus", "architecture": "Architektur",
        "church": "Kirche", "bridge": "Brücke", "room": "Raum", "kitchen": "Küche", "furniture": "Möbel",
        "car": "Auto", "vehicle": "Fahrzeug", "bicycle": "Fahrrad", "boat": "Boot", "airplane": "Flugzeug", "train": "Zug",
        "food": "Essen", "drink": "Getränk", "cake": "Kuchen", "fruit": "Obst", "meal": "Mahlzeit", "wine": "Wein",
        "document": "Dokument", "text": "Text", "paper": "Papier", "receipt": "Beleg", "screenshot": "Bildschirmfoto",
        "computer": "Computer", "electronics": "Elektronik", "sport": "Sport", "ball": "Ball", "music": "Musik",
        "art": "Kunst", "painting": "Gemälde", "sculpture": "Skulptur", "toy": "Spielzeug", "book": "Buch",
        "clothing": "Kleidung", "shoes": "Schuhe", "night_sky": "Nachthimmel", "fireworks": "Feuerwerk", "christmas": "Weihnachten",
    ]

    static func german(_ identifier: String) -> String {
        if let name = names[identifier] { return name }
        return identifier.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
