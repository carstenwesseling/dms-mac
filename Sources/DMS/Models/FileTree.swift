import Foundation

/// Darstellung der Dateiliste.
enum BrowseMode: String, CaseIterable, Identifiable, Sendable {
    case list, folders, groups
    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "Liste"
        case .folders: return "Ordner"
        case .groups: return "Gruppen"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .folders: return "folder"
        case .groups: return "square.stack.3d.up"
        }
    }
}

/// Knoten der Ordner- oder Gruppenansicht: ein Ordner bzw. eine Gruppe mit Kindern, oder eine Datei.
struct FileNode: Identifiable, Sendable {
    var id: String
    var name: String
    var path: String
    var row: FileRow?
    var children: [FileNode]?
    var fileCount: Int
    var size: Int64

    var isFolder: Bool { children != nil }
}

enum FileTree {
    /// Baut aus den Dateien eine Ordnerstruktur, je Quelle ein Wurzelknoten.
    /// Ordnerketten mit nur einem Unterordner werden zusammengefasst („Fotos/2024/Urlaub“).
    static func folders(_ rows: [FileRow], sources: [Source], extraFolders: Set<String> = []) -> [FileNode] {
        final class Builder {
            var name: String
            var path: String
            var folders: [String: Builder] = [:]
            var files: [FileRow] = []
            init(name: String, path: String) { self.name = name; self.path = path }

            func node(collapsible: Bool = true) -> FileNode {
                var children = folders.values.map { $0.node() }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                children += files
                    .sorted { $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending }
                    .map { FileNode(id: "f:\($0.id)", name: $0.file.name, path: $0.file.path, row: $0,
                                    children: nil, fileCount: 1, size: $0.file.size) }
                var result = FileNode(id: "d:" + path, name: name, path: path, row: nil, children: children,
                                      fileCount: children.reduce(0) { $0 + $1.fileCount },
                                      size: children.reduce(0) { $0 + $1.size })
                // Einzelne Unterordner ohne eigene Dateien zusammenziehen
                if collapsible, files.isEmpty, children.count == 1, let only = children.first, only.isFolder {
                    result = only
                    result.name = name + "/" + only.name
                }
                return result
            }
        }

        var roots: [Int64: Builder] = [:]
        var order: [Int64] = []
        for row in rows {
            let sourceId = row.file.sourceId
            let source = sources.first { $0.id == sourceId }
            let rootPath = source?.path ?? URL(fileURLWithPath: row.file.path).deletingLastPathComponent().path
            let root: Builder
            if let existing = roots[sourceId] {
                root = existing
            } else {
                root = Builder(name: source?.name ?? row.sourceName, path: rootPath)
                roots[sourceId] = root
                order.append(sourceId)
            }
            var relative = row.file.path.hasPrefix(rootPath + "/") ? String(row.file.path.dropFirst(rootPath.count + 1)) : row.file.name
            if relative.isEmpty { relative = row.file.name }
            var parts = relative.split(separator: "/").map(String.init)
            parts.removeLast()
            var current = root
            var path = rootPath
            for part in parts {
                path += "/" + part
                if let next = current.folders[part] {
                    current = next
                } else {
                    let next = Builder(name: part, path: path)
                    current.folders[part] = next
                    current = next
                }
            }
            current.files.append(row)
        }
        // Neu angelegte, noch leere Ordner zeigen (nur in Quellen, die schon im Baum sind)
        for folder in extraFolders.sorted() {
            guard let source = sources.first(where: { $0.contains(folder) && folder != $0.path }),
                  let sourceId = source.id, let root = roots[sourceId] else { continue }
            var current = root
            var path = source.path
            for part in folder.dropFirst(source.path.count + 1).split(separator: "/").map(String.init) {
                path += "/" + part
                if let next = current.folders[part] {
                    current = next
                } else {
                    let next = Builder(name: part, path: path)
                    current.folders[part] = next
                    current = next
                }
            }
        }
        // Wurzel nie zusammenziehen, damit der Quellenname sichtbar bleibt
        return order.compactMap { roots[$0]?.node(collapsible: false) }
    }

    /// Gruppiert gleichnamige Dateien im selben Ordner, z. B. Titel eines Albums
    /// („01_Kapitel.mp3“, „02_Kapitel.mp3“) oder Serienfotos („IMG_0001“, „IMG_0002“).
    /// Dateien ohne Partner bleiben einzeln.
    static func groups(_ rows: [FileRow]) -> [FileNode] {
        var buckets: [String: [FileRow]] = [:]
        var order: [String] = []
        for row in rows {
            let folder = URL(fileURLWithPath: row.file.path).deletingLastPathComponent().path
            let key = folder + "|" + baseName(row.file.name) + "|" + row.file.ext
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(row)
        }
        let nodes: [FileNode] = order.compactMap { key in
            guard let members = buckets[key], let first = members.first else { return nil }
            let files = members
                .sorted { $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending }
                .map { FileNode(id: "f:\($0.id)", name: $0.file.name, path: $0.file.path, row: $0,
                                children: nil, fileCount: 1, size: $0.file.size) }
            if files.count == 1 { return files[0] }
            let folder = URL(fileURLWithPath: first.file.path).deletingLastPathComponent()
            let title = displayName(first.file.name)
            return FileNode(id: "g:" + key, name: "\(title) – \(folder.lastPathComponent)", path: folder.path,
                            row: nil, children: files, fileCount: files.count,
                            size: files.reduce(0) { $0 + $1.size })
        }
        // Gruppen zuerst, größte oben; danach Einzeldateien
        return nodes.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            if a.isFolder { return a.fileCount > b.fileCount }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Name ohne Endung, Track- oder Bildnummern und Kopienzusätze, klein geschrieben.
    static func baseName(_ fileName: String) -> String {
        displayName(fileName).lowercased()
    }

    static func displayName(_ fileName: String) -> String {
        var name = (fileName as NSString).deletingPathExtension
        let patterns = [
            #"^\s*(cd|disc|teil)?\s*\d{1,3}\s*[-_.)\]]*\s*"#,  // 01_, 15 - , CD1-
            #"\s*\((\d+|kopie|copy)\)\s*$"#,                   // (1), (Kopie)
            #"[\s_-]*(teil|part|track)?[\s_-]*\d{1,5}\s*$"#,    // _0001, Teil 2
        ]
        for pattern in patterns {
            name = name.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        return name.isEmpty ? (fileName as NSString).deletingPathExtension : name
    }

    /// Ordner-IDs auf dem Weg zu einer Datei, zum Aufklappen.
    static func ancestors(of path: String, in nodes: [FileNode]) -> [String] {
        for node in nodes where node.isFolder {
            if path.hasPrefix(node.path + "/") {
                return [node.id] + ancestors(of: path, in: node.children ?? [])
            }
        }
        return []
    }
}
