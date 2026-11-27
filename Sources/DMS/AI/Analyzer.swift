import AppKit
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
                // Die groben Kategorien dienen nur der Suche; konkrete Tags kommen aus describeImages()
            }
        }
        return files.count
    }

    /// Lässt ein Bildmodell (Ollama, z. B. qwen2.5vl) das Foto ansehen und konkrete Tags vorschlagen.
    /// Ohne Bildmodell werden Screenshots und Scans über ihren erkannten Text ausgewertet.
    func describeImages(limit: Int = 1) async -> Int {
        let settings = settings()
        guard settings.enabled, let reachable = try? db.sources().filter(\.isReachable).compactMap(\.id), !reachable.isEmpty,
              let base = URL(string: settings.ollamaURL) else { return 0 }
        let visionClient = OllamaClient(baseURL: base, model: settings.visionModel)
        let hasVision = await visionClient.isAvailable()
        let textModel = hasVision ? nil : await LocalModel.find(settings: settings)
        guard hasVision || textModel != nil else { return 0 }

        let imageList = TextExtractor.imageExtensions.map { "'\($0)'" }.joined(separator: ",")
        // Ohne Bildmodell nur Bilder mit genug erkanntem Text (Screenshots, Scans); Fotos warten auf das Bildmodell
        let textFilter = hasVision ? "" : "AND length(COALESCE(c.body, '')) >= 60"
        let rows: [(FileRecord, String, String)] = (try? await db.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT file.*, a.labels AS aLabels, COALESCE(c.body, '') AS cBody FROM file
                JOIN analysis a ON a.fileId = file.id
                LEFT JOIN content c ON c.fileId = file.id
                WHERE file.ext IN (\(imageList)) AND a.model = 'vision' \(textFilter)
                  AND file.sourceId IN (\(reachable.map(String.init).joined(separator: ",")))
                ORDER BY file.modified DESC LIMIT ?
                """, arguments: [limit]).map { (try FileRecord(row: $0), ($0["aLabels"] as String?) ?? "", $0["cBody"] as String) }
        }) ?? []

        var done = 0
        for (file, labels, body) in rows {
            guard let id = file.id else { continue }
            let ocr = body.components(separatedBy: "\nBildinhalt:").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var answer: String?
            var modelName = "vision-fertig"
            do {
                if hasVision, let jpeg = Self.jpegBase64(file.url) {
                    answer = try await visionClient.generate(system: Self.systemPrompt, prompt: Self.imagePrompt(file: file, labels: labels, ocr: ocr), images: [jpeg])
                    modelName = "Ollama: \(settings.visionModel)"
                } else if let textModel, ocr.count >= 40 {
                    // Screenshot oder Scan: über den erkannten Text
                    answer = try await textModel.complete(system: Self.systemPrompt, prompt: Self.imagePrompt(file: file, labels: labels, ocr: ocr))
                    modelName = textModel.name
                }
            } catch {
                NSLog("DMS Bildbeschreibung fehlgeschlagen für \(file.name): \(error)")
            }
            let parsed = answer.map(Self.parse)
            let usedModel = modelName
            try? await db.writer.write { db in
                try db.execute(sql: "UPDATE analysis SET summary = ?, model = ?, at = ? WHERE fileId = ?",
                               arguments: [parsed?.summary, usedModel, Date(), id])
                if let parsed {
                    if !parsed.summary.isEmpty {
                        let extra = "Beschreibung: " + parsed.summary + " " + parsed.tags.joined(separator: " ")
                        try db.execute(sql: "UPDATE content SET body = body || ? WHERE fileId = ?", arguments: ["\n" + extra, id])
                        try AppDatabase.reindexFTS(db, fileId: id)
                    }
                    for tag in parsed.tags.prefix(5) {
                        try Self.suggestTag(db, fileId: id, tag: tag, reason: "KI-Vorschlag")
                    }
                }
            }
            done += 1
        }
        return done
    }

    static func imagePrompt(file: FileRecord, labels: String, ocr: String) -> String {
        var context = "Dateiname: \(file.name)\nAufgenommen/geändert: \(file.modified.formatted(.dateTime.year().month(.wide)))"
        if !labels.isEmpty { context += "\nGrobe Bildkategorien: \(labels)" }
        if !ocr.isEmpty { context += "\nText im Bild:\n\(ocr.prefix(2000))" }
        return """
            \(context)

            Aufgabe: Beschreibe in einem Satz, was konkret zu sehen ist bzw. worum es geht.
            Nenne danach 3 bis 5 KONKRETE Schlagwörter, die beim späteren Suchen helfen: \
            Ort oder Sehenswürdigkeit, Anlass oder Ereignis, Firma oder Absender, Produkt, Tier- oder Pflanzenart, Thema. \
            Verboten sind allgemeine Wörter wie Bild, Foto, Bildschirmfoto, Screenshot, Dokument, Text, Mensch, Person, Draußen, Drinnen. \
            Bei Screenshots: Name der App oder Webseite und das Thema.
            Antworte genau in diesem Format:
            ZUSAMMENFASSUNG: <Satz>
            SCHLAGWÖRTER: <Wort>, <Wort>, <Wort>
            """
    }

    /// Bild verkleinert als JPEG (Base64) für das Bildmodell.
    static func jpegBase64(_ url: URL) -> String? {
        guard let image = TextExtractor.loadImage(url, maxPixel: 1024) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?.base64EncodedString()
    }

    /// Zu allgemeine Begriffe, die bei der Suche nicht weiterhelfen.
    static let genericTags: Set<String> = [
        "bild", "bilder", "foto", "fotos", "bildschirmfoto", "screenshot", "dokument", "dokumente", "datei", "text",
        "mensch", "menschen", "person", "personen", "draußen", "drinnen", "objekt", "inhalt", "sonstiges", "allgemein",
        "papier", "information", "informationen", "seite", "grafik", "abbildung", "aufnahme",
    ]

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

            Aufgabe: Fasse den Inhalt in 2 bis 3 Sätzen zusammen. Nenne danach 3 bis 5 KONKRETE Schlagwörter, \
            die beim Wiederfinden helfen: Absender oder Firma, Art des Dokuments, Thema, Jahr \
            (z. B. Telekom, Stromrechnung, Kfz-Versicherung, Steuer 2024). Keine allgemeinen Wörter wie Dokument, Text oder Datei.
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
                    .filter { !$0.isEmpty && $0.count <= 30 && !genericTags.contains($0.lowercased()) }
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
