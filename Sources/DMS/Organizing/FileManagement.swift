import Foundation
import GRDB

/// Verschieben, Kopieren und Löschen von Dateien und Ordnern aus der Ordneransicht.
/// Der Index wird sofort angepasst, damit Tags, Text und Zusammenfassungen beim Verschieben erhalten bleiben.
extension Organizer {
    struct Outcome: Sendable {
        var done = 0
        var errors: [String] = []
    }

    /// Verschiebt Dateien und Ordner in einen Zielordner. Jede Aktion steht im Protokoll und lässt sich rückgängig machen.
    func move(_ urls: [URL], into folder: URL) -> Outcome {
        var outcome = Outcome()
        let sources = (try? db.sources()) ?? []
        for url in Self.topLevel(urls) {
            let name = url.lastPathComponent
            if url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path { continue }
            if folder.path == url.path || folder.path.hasPrefix(url.path + "/") {
                outcome.errors.append("\(name): Ein Ordner kann nicht in sich selbst verschoben werden.")
                continue
            }
            do {
                let result = try FileOps.safeMove(from: url, to: folder.appendingPathComponent(name))
                try updateIndex(from: url.path, to: result.finalPath, sources: sources)
                try db.writer.write { db in
                    var entry = ActionLogEntry(id: nil, at: Date(), kind: "move", fromPath: url.path, toPath: result.finalPath,
                                               trashPath: result.trashPath, undone: false)
                    try entry.insert(db)
                }
                outcome.done += 1
            } catch {
                outcome.errors.append("\(name): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    /// Kopiert Dateien und Ordner in einen Zielordner; die Kopien werden gleich in den Index aufgenommen.
    func copy(_ urls: [URL], into folder: URL) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        var created: [String] = []
        for url in Self.topLevel(urls) {
            let name = url.lastPathComponent
            if folder.path == url.path || folder.path.hasPrefix(url.path + "/") {
                outcome.errors.append("\(name): Ein Ordner kann nicht in sich selbst kopiert werden.")
                continue
            }
            do {
                guard FileOps.isReachable(folder.path) else { throw FileOps.OpError.targetUnreachable(folder.path) }
                let target = FileOps.uniqueURL(for: folder.appendingPathComponent(name))
                try fm.copyItem(at: url, to: target)
                created.append(target.path)
                outcome.done += 1
            } catch {
                outcome.errors.append("\(name): \(error.localizedDescription)")
            }
        }
        indexer.refresh(paths: created, sources: (try? db.sources()) ?? [])
        return outcome
    }

    /// Legt Dateien und Ordner in den Papierkorb (auf dem NAS in „DMS-Papierkorb“) und nimmt sie aus dem Index.
    func trash(_ urls: [URL]) -> Outcome {
        var outcome = Outcome()
        for url in Self.topLevel(urls) {
            do {
                let trash = try FileOps.moveToTrash(url)
                try db.writer.write { db in
                    var entry = ActionLogEntry(id: nil, at: Date(), kind: "trash", fromPath: url.path, toPath: trash,
                                               trashPath: trash, undone: false)
                    try entry.insert(db)
                    try db.execute(sql: "DELETE FROM file WHERE " + Self.underPath("path"), arguments: Self.underPathArgs(url.path))
                }
                outcome.done += 1
            } catch {
                outcome.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    /// Pfade im Index nach dem Verschieben anpassen (Datei oder ganzer Ordner).
    func updateIndex(from old: String, to new: String, sources: [Source]) throws {
        let destSource = sources.first { $0.contains(new) }
        try db.writer.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, path FROM file WHERE " + Self.underPath("path"),
                                        arguments: Self.underPathArgs(old))
            let oldLength = old.unicodeScalars.count
            for row in rows {
                let id: Int64 = row["id"]
                let path: String = row["path"]
                let newPath = new + String(String.UnicodeScalarView(path.unicodeScalars.dropFirst(oldLength)))
                let name = URL(fileURLWithPath: newPath).lastPathComponent
                if let sourceId = destSource?.id {
                    try db.execute(sql: "UPDATE file SET path = ?, name = ?, sourceId = ? WHERE id = ?",
                                   arguments: [newPath, name, sourceId, id])
                    try AppDatabase.reindexFTS(db, fileId: id)
                } else {
                    // Ziel liegt außerhalb der eingebundenen Quellen: nicht mehr im Index führen
                    _ = try FileRecord.deleteOne(db, key: id)
                }
            }
            var args: StatementArguments = [new, oldLength + 1]
            args += Self.underPathArgs(old)
            try db.execute(sql: "UPDATE fileVersion SET originalPath = ? || substr(originalPath, ?) WHERE " + Self.underPath("originalPath"),
                           arguments: args)
        }
    }

    /// SQL-Bedingung „genau dieser Pfad oder darunter“, mit exaktem Vergleich (LIKE ignoriert Groß/Klein).
    static func underPath(_ column: String) -> String {
        "(\(column) = ? OR substr(\(column), 1, ?) = ?)"
    }

    static func underPathArgs(_ path: String) -> StatementArguments {
        let prefix = path + "/"
        return [path, prefix.unicodeScalars.count, prefix]
    }

    /// Nur die obersten Einträge: Liegt eine Datei in einem ebenfalls gewählten Ordner, wird sie mit ihm bewegt.
    static func topLevel(_ urls: [URL]) -> [URL] {
        let paths = Set(urls.map(\.path))
        return urls.filter { url in
            !paths.contains { url.path.hasPrefix($0 + "/") }
        }
        .reduce(into: [URL]()) { result, url in
            if !result.contains(where: { $0.path == url.path }) { result.append(url) }
        }
    }
}
