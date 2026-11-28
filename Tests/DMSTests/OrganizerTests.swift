import GRDB
import XCTest
@testable import DMS

final class OrganizerTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dms-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeFile(_ relative: String, _ content: String) throws -> URL {
        let url = tmp.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testTiers() {
        var settings = StorageSettings()
        settings.macDays = 60
        settings.driveDays = 183
        let now = Date()
        XCTAssertEqual(Organizer.tier(lastActivity: now.addingTimeInterval(-10 * 86_400), now: now, settings: settings), .mac)
        XCTAssertEqual(Organizer.tier(lastActivity: now.addingTimeInterval(-90 * 86_400), now: now, settings: settings), .drive)
        XCTAssertEqual(Organizer.tier(lastActivity: now.addingTimeInterval(-400 * 86_400), now: now, settings: settings), .nas)
    }

    func testSafeMoveAndUndo() throws {
        let src = try makeFile("a/Brief.txt", "Hallo")
        let target = tmp.appendingPathComponent("b/Brief.txt")
        let result = try FileOps.safeMove(from: src, to: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.finalPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))

        let entry = ActionLogEntry(id: 1, at: Date(), kind: "move", fromPath: src.path, toPath: result.finalPath, trashPath: result.trashPath, undone: false)
        try FileOps.undo(entry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(try String(contentsOf: src, encoding: .utf8), "Hallo")
    }

    func testMoveFolderKeepsIndexAndTags() throws {
        let db = try AppDatabase.inMemory()
        let organizer = Organizer(db: db, indexer: Indexer(db: db))
        let file = try makeFile("Quelle/Fotos/Urlaub/bild.txt", "Strand")
        let target = tmp.appendingPathComponent("Quelle/Archiv")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        var fileId: Int64 = 0
        try db.writer.write { db in
            var source = Source(id: nil, name: "Quelle", kind: .local, path: self.tmp.appendingPathComponent("Quelle").path,
                                remoteURL: nil, lastScan: nil)
            try source.insert(db)
            var rec = FileRecord(id: nil, sourceId: source.id!, path: file.path, name: "bild.txt", ext: "txt", typeIdentifier: nil,
                                 size: 6, modified: Date(), created: nil, lastUsed: nil, contentHash: nil, textState: .done, scanMark: 1)
            try rec.insert(db)
            fileId = rec.id!
        }
        try db.addTag("Strand", to: [fileId])

        let folder = tmp.appendingPathComponent("Quelle/Fotos")
        let outcome = organizer.move([folder, file], into: target)
        XCTAssertEqual(outcome.errors, [])
        XCTAssertEqual(outcome.done, 1, "Datei im mitverschobenen Ordner zählt nicht doppelt")
        let newPath = target.appendingPathComponent("Fotos/Urlaub/bild.txt").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPath))
        let moved = try db.reader.read { db in try FileRecord.fetchOne(db, key: fileId) }
        XCTAssertEqual(moved?.path, newPath)
        XCTAssertEqual(try db.search("Strand").count, 1, "Tag bleibt erhalten")

        let copy = organizer.copy([target.appendingPathComponent("Fotos")], into: tmp.appendingPathComponent("Quelle"))
        XCTAssertEqual(copy.done, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("Quelle/Fotos/Urlaub/bild.txt").path))
    }

    func testMoveIntoItselfIsRefused() throws {
        let db = try AppDatabase.inMemory()
        let organizer = Organizer(db: db, indexer: Indexer(db: db))
        _ = try makeFile("A/B/x.txt", "x")
        let outcome = organizer.move([tmp.appendingPathComponent("A")], into: tmp.appendingPathComponent("A/B"))
        XCTAssertEqual(outcome.done, 0)
        XCTAssertEqual(outcome.errors.count, 1)
    }

    func testUniqueNameDoesNotOverwrite() throws {
        _ = try makeFile("x/Datei.pdf", "1")
        let unique = FileOps.uniqueURL(for: tmp.appendingPathComponent("x/Datei.pdf"))
        XCTAssertEqual(unique.lastPathComponent, "Datei (2).pdf")
    }

    func testPlannerSuggestsArchiveForOldFile() throws {
        let db = try AppDatabase.inMemory()
        let indexer = Indexer(db: db)
        let organizer = Organizer(db: db, indexer: indexer)
        let srcDir = tmp.appendingPathComponent("Dokumente")
        let file = try makeFile("Dokumente/Steuer/alt.txt", "Steuerbescheid 2020")
        let archive = tmp.appendingPathComponent("Archiv").path

        var settings = StorageSettings()
        settings.nasTarget = archive
        try organizer.save(settings)

        try db.writer.write { db in
            var source = Source(id: nil, name: "Dokumente", kind: .local, path: srcDir.path, remoteURL: nil, lastScan: nil)
            try source.insert(db)
            var rec = FileRecord(id: nil, sourceId: source.id!, path: file.path, name: "alt.txt", ext: "txt", typeIdentifier: nil,
                                 size: 19, modified: Date(timeIntervalSinceNow: -500 * 86_400), created: nil, lastUsed: nil,
                                 contentHash: nil, textState: .done, scanMark: 1)
            try rec.insert(db)
            try db.execute(sql: "INSERT INTO content(fileId, body, method) VALUES (?, 'Steuerbescheid 2020', 'text')", arguments: [rec.id])
            try AppDatabase.reindexFTS(db, fileId: rec.id!)
        }

        try organizer.planSuggestions()
        var rows = try organizer.suggestions(status: [.open])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.suggestion.target, archive + "/Dokumente/Steuer/alt.txt")

        // Rejected suggestions are not proposed again
        try organizer.setStatus(rows.map(\.id), .rejected)
        try organizer.planSuggestions()
        XCTAssertTrue(try organizer.suggestions(status: [.open]).isEmpty)

        // A rule with a fixed location wins over the tier, and can add a tag
        let fixed = tmp.appendingPathComponent("Steuerordner").path
        try organizer.save(Rule(id: nil, name: "Steuer", field: .content, value: "Steuerbescheid", addTag: "Steuer", targetPath: fixed))
        try organizer.planSuggestions()
        rows = try organizer.suggestions(status: [.open])
        XCTAssertTrue(rows.contains { $0.suggestion.kind == .move && $0.suggestion.target == fixed + "/alt.txt" })
        XCTAssertTrue(rows.contains { $0.suggestion.kind == .tag && $0.suggestion.target == "Steuer" })

        // Executing the move updates the log
        try organizer.setStatus(rows.map(\.id), .queued)
        XCTAssertEqual(organizer.processQueue(), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixed + "/alt.txt"))
        XCTAssertEqual(try organizer.log().count, 1)
    }

    func testDuplicateGroups() throws {
        let db = try AppDatabase.inMemory()
        let organizer = Organizer(db: db, indexer: Indexer(db: db))
        let a = try makeFile("s/a.txt", "gleich")
        let b = try makeFile("s/kopie/b.txt", "gleich")
        try db.writer.write { db in
            var source = Source(id: nil, name: "S", kind: .local, path: tmp.appendingPathComponent("s").path, remoteURL: nil, lastScan: nil)
            try source.insert(db)
            for url in [a, b] {
                var rec = FileRecord(id: nil, sourceId: source.id!, path: url.path, name: url.lastPathComponent, ext: "txt", typeIdentifier: nil,
                                     size: 6, modified: Date(), created: nil, lastUsed: nil, contentHash: nil, textState: .done, scanMark: 1)
                try rec.insert(db)
            }
        }
        XCTAssertEqual(organizer.hashCandidates(), 2)
        let groups = try organizer.duplicateGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.files.count, 2)
    }
}

final class AnalyzerTests: XCTestCase {
    func testParsesModelAnswer() {
        let answer = """
            <think>überlegen</think>
            **ZUSAMMENFASSUNG:** Stromrechnung der Stadtwerke für 2024.
            Fällig am 15. März.
            SCHLAGWÖRTER: Rechnung, Strom, Stadtwerke, 2024.
            """
        let parsed = Analyzer.parse(answer)
        XCTAssertEqual(parsed.summary, "Stromrechnung der Stadtwerke für 2024. Fällig am 15. März.")
        XCTAssertEqual(parsed.tags, ["Rechnung", "Strom", "Stadtwerke", "2024"])
    }

    func testGermanImageLabels() {
        XCTAssertEqual(ImageLabels.german("beach"), "Strand")
        XCTAssertEqual(ImageLabels.german("hot_air_balloon"), "Hot Air Balloon")
    }

    func testAITagSuggestionsSurviveReplanning() throws {
        let db = try AppDatabase.inMemory()
        let organizer = Organizer(db: db, indexer: Indexer(db: db))
        try db.writer.write { db in
            var source = Source(id: nil, name: "S", kind: .local, path: "/tmp/dms-ai-test", remoteURL: nil, lastScan: nil)
            try source.insert(db)
            var file = FileRecord(id: nil, sourceId: source.id!, path: "/tmp/dms-ai-test/a.pdf", name: "a.pdf", ext: "pdf",
                                  typeIdentifier: nil, size: 1, modified: Date(), created: nil, lastUsed: nil,
                                  contentHash: nil, textState: .done, scanMark: 1)
            try file.insert(db)
            try Analyzer.suggestTag(db, fileId: file.id!, tag: "Rechnung", reason: "KI-Vorschlag")
        }
        try organizer.planSuggestions()
        XCTAssertEqual(try organizer.suggestions(status: [.open]).filter { $0.suggestion.kind == .tag }.count, 1)
    }
}

final class GenericTagTests: XCTestCase {
    func testGenericTagsAreFiltered() {
        let parsed = Analyzer.parse("ZUSAMMENFASSUNG: Hafen bei Sonnenuntergang.\nSCHLAGWÖRTER: Foto, Hamburger Hafen, Bildschirmfoto, Elbphilharmonie, Mensch")
        XCTAssertEqual(parsed.tags, ["Hamburger Hafen", "Elbphilharmonie"])
    }

    func testOldSettingsStillDecode() throws {
        let old = #"{"enabled":true,"ollamaURL":"http://localhost:11434","ollamaModel":"qwen2.5:3b"}"#
        let decoded = try JSONDecoder().decode(AISettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.visionModel, "qwen2.5vl:3b")
    }
}

final class DashboardInsightsTests: XCTestCase {
    func testUnreadableFilesAreNoDuplicates() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            var source = Source(id: nil, name: "Q", kind: .local, path: "/q", remoteURL: nil, lastScan: nil)
            try source.insert(db)
            // Nicht lesbare Dateien bekommen eine leere Prüfsumme und sind keine Dubletten
            for (i, hash) in ["", "", "", "abc", "abc"].enumerated() {
                var f = FileRecord(id: nil, sourceId: source.id!, path: "/q/\(i).txt", name: "\(i).txt", ext: "txt",
                                   typeIdentifier: nil, size: 10, modified: Date(), created: nil, lastUsed: nil,
                                   contentHash: hash, textState: .done, scanMark: 1)
                try f.insert(db)
            }
        }
        let insights = try db.dashboardInsights()
        XCTAssertEqual(insights.duplicateFiles, 1)
        XCTAssertEqual(insights.duplicateBytes, 10)
    }
}

final class ProcessingTests: XCTestCase {
    func testRestartResetsOnlyFailures() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            var source = Source(id: nil, name: "Q", kind: .local, path: "/q", remoteURL: nil, lastScan: nil)
            try source.insert(db)
            let states: [(TextState, String?)] = [(.failed, ""), (.done, "abc"), (.done, nil), (.empty, nil)]
            for (i, (state, hash)) in states.enumerated() {
                var f = FileRecord(id: nil, sourceId: source.id!, path: "/q/\(i).pdf", name: "\(i).pdf", ext: "pdf",
                                   typeIdentifier: nil, size: 10, modified: Date(), created: nil, lastUsed: nil,
                                   contentHash: hash, textState: state, scanMark: 1)
                try f.insert(db)
            }
            try db.execute(sql: "INSERT INTO analysis(fileId, summary, labels, model, at) VALUES (2, NULL, NULL, 'fehler', ?)", arguments: [Date()])
            try db.execute(sql: "INSERT INTO analysis(fileId, summary, labels, model, at) VALUES (3, 'Rechnung', 'Strom', 'qwen', ?)", arguments: [Date()])
        }
        XCTAssertEqual(try db.processingStats().textFailed, 1)
        XCTAssertEqual(try db.processingStats().aiFailed, 1)
        XCTAssertEqual(try db.resetFailedCapture(), 2)
        XCTAssertEqual(try db.resetFailedTagging(), 1)
        let s = try db.processingStats()
        XCTAssertEqual(s.textFailed, 0)
        XCTAssertEqual(s.hashFailed, 0)
        XCTAssertEqual(s.textPending, 1)
        XCTAssertEqual(s.aiFailed, 0)
        XCTAssertEqual(s.docsDone, 1)
    }
}

final class PhotoTextTests: XCTestCase {
    func testQuickTextCheck() {
        XCTAssertFalse(OCR.looksLikeText(""))
        XCTAssertFalse(OCR.looksLikeText("Il ."))
        XCTAssertFalse(OCR.looksLikeText("EXIT"))
        XCTAssertTrue(OCR.looksLikeText("Rechnung Nr. 2024-118\nStadtwerke München\nBetrag 84,20 EUR"))
    }
}

final class PreviewTextTests: XCTestCase {
    func testLenientCheckForSmallPreviews() {
        XCTAssertFalse(OCR.mightContainText("I l ."))
        XCTAssertTrue(OCR.mightContainText("STOP"))
    }
}

final class CaptureSettingsTests: XCTestCase {
    func testDisablingImagesSkipsPendingPhotos() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            var source = Source(id: nil, name: "Q", kind: .local, path: "/q", remoteURL: nil, lastScan: nil)
            try source.insert(db)
            for (i, ext) in ["jpg", "JPG", "pdf"].enumerated() {
                var f = FileRecord(id: nil, sourceId: source.id!, path: "/q/\(i).\(ext)", name: "\(i).\(ext)", ext: ext,
                                   typeIdentifier: nil, size: 10, modified: Date(), created: nil, lastUsed: nil,
                                   contentHash: nil, textState: .pending, scanMark: 1)
                try f.insert(db)
            }
        }
        XCTAssertEqual(try db.applyCapture(.bilder, enabled: false), 2)
        XCTAssertEqual(try db.processingStats().textPending, 1)
        XCTAssertEqual(try db.applyCapture(.bilder, enabled: true), 2)
        XCTAssertEqual(try db.processingStats().textPending, 3)
    }
}

final class MediaCaptureTests: XCTestCase {
    func testDisabledVideosAreExcludedFromHashing() {
        let before = CaptureSettings.isEnabled(.videos)
        defer { CaptureSettings.setEnabled(.videos, before) }
        CaptureSettings.setEnabled(.videos, false)
        XCTAssertTrue(CaptureSettings.excludedFromHashing.contains("mp4"))
        CaptureSettings.setEnabled(.videos, true)
        XCTAssertFalse(CaptureSettings.excludedFromHashing.contains("mp4"))
    }
}
