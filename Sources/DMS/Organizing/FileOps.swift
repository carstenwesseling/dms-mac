import CryptoKit
import Foundation

/// Sichere Dateioperationen: Kopieren mit Prüfsumme, Original in den Papierkorb, Rückgängig.
enum FileOps {
    enum OpError: LocalizedError {
        case sourceMissing(String)
        case targetUnreachable(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceMissing(let p): return "Datei nicht gefunden: \(p)"
            case .targetUnreachable(let p): return "Ziel nicht erreichbar: \(p)"
            case .verificationFailed(let p): return "Prüfung der Kopie fehlgeschlagen: \(p)"
            }
        }
    }

    struct MoveResult {
        var finalPath: String
        var trashPath: String?
    }

    /// SHA-256 über den Dateiinhalt, in Blöcken gelesen (auch für große Dateien auf dem NAS).
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) ?? Data() }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Freier Name im Zielordner: "Datei.pdf", sonst "Datei (2).pdf" usw.
    static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Bei Pfaden unter /Volumes muss das Laufwerk (z. B. CAWServer) eingebunden sein.
    static func isReachable(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).pathComponents
        if parts.count > 2, parts[1] == "Volumes" {
            return FileManager.default.fileExists(atPath: "/Volumes/\(parts[2])")
        }
        return true
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = try? a.resourceValues(forKeys: keys).volumeIdentifier as? NSObject,
              let vb = try? b.resourceValues(forKeys: keys).volumeIdentifier as? NSObject else { return false }
        return va.isEqual(vb)
    }

    /// Verschiebt eine Datei sicher.
    /// Gleiches Laufwerk: einfaches Umbenennen. Anderes Laufwerk: kopieren, Prüfsumme vergleichen,
    /// erst dann das Original in den Papierkorb legen.
    static func safeMove(from source: URL, to target: URL) throws -> MoveResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { throw OpError.sourceMissing(source.path) }
        if isDir.boolValue { return try safeMoveFolder(from: source, to: target) }
        let targetDir = target.deletingLastPathComponent()
        if !isReachable(targetDir.path) {
            throw OpError.targetUnreachable(targetDir.path)
        }
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let finalURL = uniqueURL(for: target)

        if sameVolume(source, targetDir) {
            try fm.moveItem(at: source, to: finalURL)
            return MoveResult(finalPath: finalURL.path, trashPath: nil)
        }

        let tempURL = targetDir.appendingPathComponent(".dms-\(UUID().uuidString).tmp")
        do {
            try fm.copyItem(at: source, to: tempURL)
            guard try sha256(source) == sha256(tempURL) else {
                throw OpError.verificationFailed(finalURL.path)
            }
            try fm.moveItem(at: tempURL, to: finalURL)
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
        let trash = try moveToTrash(source)
        return MoveResult(finalPath: finalURL.path, trashPath: trash)
    }

    /// Verschiebt einen Ordner. Gleiches Laufwerk: umbenennen. Sonst kopieren, Anzahl und Größe
    /// aller Dateien vergleichen und erst dann das Original in den Papierkorb legen.
    static func safeMoveFolder(from source: URL, to target: URL) throws -> MoveResult {
        let fm = FileManager.default
        let targetDir = target.deletingLastPathComponent()
        if !isReachable(targetDir.path) { throw OpError.targetUnreachable(targetDir.path) }
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let finalURL = uniqueURL(for: target)
        if sameVolume(source, targetDir) {
            try fm.moveItem(at: source, to: finalURL)
            return MoveResult(finalPath: finalURL.path, trashPath: nil)
        }
        let tempURL = targetDir.appendingPathComponent(".dms-\(UUID().uuidString).tmp")
        do {
            try fm.copyItem(at: source, to: tempURL)
            guard folderFingerprint(source) == folderFingerprint(tempURL) else {
                throw OpError.verificationFailed(finalURL.path)
            }
            try fm.moveItem(at: tempURL, to: finalURL)
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
        let trash = try moveToTrash(source)
        return MoveResult(finalPath: finalURL.path, trashPath: trash)
    }

    /// Anzahl Dateien und Gesamtgröße eines Ordners, zum Prüfen einer Kopie.
    static func folderFingerprint(_ url: URL) -> (Int, Int64) {
        var count = 0
        var size: Int64 = 0
        let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let item = en?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                count += 1
                size += Int64(values?.fileSize ?? 0)
            }
        }
        return (count, size)
    }

    /// Legt eine Datei in den Papierkorb. Auf Netzlaufwerken ohne Papierkorb in einen Ordner
    /// "DMS-Papierkorb" im obersten Ordner der Freigabe.
    static func moveToTrash(_ url: URL) throws -> String {
        let fm = FileManager.default
        do {
            var resulting: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &resulting)
            return (resulting as URL?)?.path ?? ""
        } catch {
            let components = url.pathComponents
            let volumeRoot: URL
            if components.count > 2, components[1] == "Volumes" {
                volumeRoot = URL(fileURLWithPath: "/Volumes/\(components[2])", isDirectory: true)
            } else {
                volumeRoot = fm.homeDirectoryForCurrentUser
            }
            let trashDir = volumeRoot.appendingPathComponent("DMS-Papierkorb", isDirectory: true)
            try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let dest = uniqueURL(for: trashDir.appendingPathComponent(url.lastPathComponent))
            try fm.moveItem(at: url, to: dest)
            return dest.path
        }
    }

    /// Macht eine Verschiebung oder ein Löschen rückgängig.
    static func undo(_ entry: ActionLogEntry) throws {
        let fm = FileManager.default
        let original = URL(fileURLWithPath: entry.fromPath)
        switch entry.kind {
        case "trash":
            guard fm.fileExists(atPath: entry.toPath) else { throw OpError.sourceMissing(entry.toPath) }
            try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: URL(fileURLWithPath: entry.toPath), to: uniqueURL(for: original))
        default: // move
            if let trash = entry.trashPath, !trash.isEmpty, fm.fileExists(atPath: trash) {
                // Original liegt noch im Papierkorb: zurückholen, Kopie am Ziel wegräumen
                try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: URL(fileURLWithPath: trash), to: uniqueURL(for: original))
                if fm.fileExists(atPath: entry.toPath) {
                    _ = try moveToTrash(URL(fileURLWithPath: entry.toPath))
                }
            } else {
                _ = try safeMove(from: URL(fileURLWithPath: entry.toPath), to: original)
            }
        }
    }
}
