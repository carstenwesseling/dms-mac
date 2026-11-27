import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dateien als aufklappbare Ordnerstruktur oder als Gruppen gleichnamiger Dateien (z. B. ein Album).
/// In der Ordneransicht lassen sich Dateien und Ordner markieren, per Ziehen verschieben,
/// ausschneiden, kopieren, einfügen und löschen.
struct FileTreeView: View {
    @EnvironmentObject private var state: AppState
    let mode: BrowseMode
    @State private var nodes: [FileNode] = []
    @State private var index: [String: FileNode] = [:]
    @State private var expanded: Set<String> = []
    @State private var nodeSelection: Set<String> = []
    @State private var pendingDelete: [URL] = []
    @State private var confirmDelete = false

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $nodeSelection) {
                ForEach(nodes) { node in
                    NodeRow(node: node, expanded: $expanded, canEdit: mode == .folders, onDrop: drop)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { ids in
                menu(for: ids)
            } primaryAction: { ids in
                rows(for: ids).forEach(state.open)
            }
            .onCopyCommand { copyCommand(cut: false) }
            .onCutCommand { copyCommand(cut: true) }
            .onPasteCommand(of: [.fileURL]) { _ in
                if let folder = targetFolder(for: nodeSelection) { state.paste(into: folder) }
            }
            .onDeleteCommand { askDelete(urls(for: nodeSelection)) }
            .onChange(of: nodeSelection) {
                state.selection = Set(nodeSelection.compactMap { $0.hasPrefix("f:") ? Int64($0.dropFirst(2)) : nil })
            }
            .task(id: TreeKey(rows: state.rows.map(\.id), mode: mode)) {
                await rebuild()
                revealIfNeeded(proxy)
            }
            .onChange(of: state.revealPath) { revealIfNeeded(proxy) }
            .overlay {
                if state.rows.isEmpty {
                    ContentUnavailableView.search(text: state.query)
                }
            }
            .overlay(alignment: .bottom) {
                if state.fileOperationRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Wird ausgeführt …")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
                }
            }
            .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("In den Papierkorb legen", role: .destructive) { state.trash(pendingDelete) }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Die Elemente werden an ihrem Speicherort gelöscht und landen im Papierkorb (auf CAWServer im Ordner „DMS-Papierkorb“). Im Protokoll kannst du das rückgängig machen.")
            }
        }
    }

    // MARK: Kontextmenü

    @ViewBuilder
    private func menu(for ids: Set<String>) -> some View {
        let urls = urls(for: ids)
        let files = rows(for: ids)
        if !files.isEmpty {
            Button("Öffnen") { files.forEach(state.open) }
        }
        if !urls.isEmpty {
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        if mode == .folders {
            Divider()
            Button("Ausschneiden") { state.copyToClipboard(urls, cut: true) }
                .disabled(urls.isEmpty)
            Button("Kopieren") { state.copyToClipboard(urls, cut: false) }
                .disabled(urls.isEmpty)
            if let clip = state.clipboard, let folder = targetFolder(for: ids) {
                Button("\(clip.urls.count) Element(e) hier einfügen") { state.paste(into: folder) }
            }
            Divider()
            Button("Löschen …", role: .destructive) { askDelete(urls) }
                .disabled(urls.isEmpty)
        }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "„\(pendingDelete[0].lastPathComponent)“ löschen?" : "\(pendingDelete.count) Elemente löschen?"
    }

    private func askDelete(_ urls: [URL]) {
        guard mode == .folders, !urls.isEmpty else { return }
        pendingDelete = urls
        confirmDelete = true
    }

    private func copyCommand(cut: Bool) -> [NSItemProvider] {
        let urls = urls(for: nodeSelection)
        if mode == .folders { state.copyToClipboard(urls, cut: cut) }
        return urls.map { NSItemProvider(object: $0 as NSURL) }
    }

    // MARK: Ziehen und Ablegen

    /// Abgelegte Elemente in den Ordner verschieben. Wird ein markiertes Element gezogen,
    /// wandern alle markierten mit. Dateien von außerhalb der Quellen (z. B. aus dem Finder) werden kopiert.
    private func drop(_ dropped: [URL], into folder: URL) -> Bool {
        guard mode == .folders, !dropped.isEmpty else { return false }
        let selected = urls(for: nodeSelection)
        let selectedPaths = Set(selected.map(\.path))
        let items = dropped.contains { selectedPaths.contains($0.path) } ? selected : dropped
        let inside = items.filter { url in state.sources.contains { $0.contains(url.path) } }
        let outside = items.filter { url in !state.sources.contains { $0.contains(url.path) } }
        if !inside.isEmpty { state.move(inside, into: folder) }
        if !outside.isEmpty { state.copy(outside, into: folder) }
        expanded.insert("d:" + folder.path)
        return true
    }

    // MARK: Auswahl

    private struct TreeKey: Equatable {
        var rows: [Int64]
        var mode: BrowseMode
    }

    private func rows(for ids: Set<String>) -> [FileRow] {
        let wanted = Set(ids.compactMap { $0.hasPrefix("f:") ? Int64($0.dropFirst(2)) : nil })
        return state.rows.filter { wanted.contains($0.id) }
    }

    /// Dateisystem-Pfade der markierten Einträge; eine Gruppe steht für ihre Dateien.
    private func urls(for ids: Set<String>) -> [URL] {
        ids.flatMap { id -> [URL] in
            guard let node = index[id] else { return [] }
            if id.hasPrefix("g:") { return (node.children ?? []).map { URL(fileURLWithPath: $0.path) } }
            return [URL(fileURLWithPath: node.path)]
        }
    }

    /// Ordner, in den eingefügt wird: der markierte Ordner, sonst der Ordner der markierten Datei.
    private func targetFolder(for ids: Set<String>) -> URL? {
        guard ids.count == 1, let id = ids.first, let node = index[id] else { return nil }
        if id.hasPrefix("d:") || id.hasPrefix("g:") { return URL(fileURLWithPath: node.path, isDirectory: true) }
        return URL(fileURLWithPath: node.path).deletingLastPathComponent()
    }

    private func rebuild() async {
        let rows = state.rows
        let sources = state.sources
        let mode = self.mode
        let built = await Task.detached(priority: .userInitiated) {
            mode == .groups ? FileTree.groups(rows) : FileTree.folders(rows, sources: sources)
        }.value
        nodes = built
        var flat: [String: FileNode] = [:]
        func add(_ list: [FileNode]) {
            for node in list {
                flat[node.id] = node
                if let children = node.children { add(children) }
            }
        }
        add(built)
        index = flat
        if mode == .folders {
            expanded.formUnion(built.map(\.id))
        }
        nodeSelection = nodeSelection.filter { flat[$0] != nil }
            .union(state.selection.map { "f:\($0)" }.filter { flat[$0] != nil })
    }

    private func revealIfNeeded(_ proxy: ScrollViewProxy) {
        guard let path = state.revealPath, !nodes.isEmpty else { return }
        let chain = FileTree.ancestors(of: path, in: nodes)
        guard !chain.isEmpty else { return }
        expanded.formUnion(chain)
        if let row = state.rows.first(where: { $0.file.path == path }) {
            nodeSelection = ["f:\(row.id)"]
            state.selection = [row.id]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation { proxy.scrollTo("f:\(row.id)", anchor: .center) }
            }
        }
        state.revealPath = nil
    }
}

/// Eine Zeile: Ordner/Gruppe mit Aufklappen oder Datei. Ordner nehmen abgelegte Elemente an.
private struct NodeRow: View {
    let node: FileNode
    @Binding var expanded: Set<String>
    let canEdit: Bool
    let onDrop: ([URL], URL) -> Bool
    @State private var targeted = false

    private var isGroup: Bool { node.id.hasPrefix("g:") }

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(node.id) },
                set: { open in if open { expanded.insert(node.id) } else { expanded.remove(node.id) } }
            )) {
                ForEach(children) { child in
                    NodeRow(node: child, expanded: $expanded, canEdit: canEdit, onDrop: onDrop)
                }
            } label: {
                label(icon: isGroup ? "square.stack.3d.up" : "folder", highlight: true)
                    .background(RoundedRectangle(cornerRadius: 5).fill(targeted ? Theme.accent.opacity(0.25) : .clear))
                    .modifier(DragSource(path: node.path, enabled: canEdit && !isGroup))
                    .modifier(DropTarget(enabled: canEdit && !isGroup, targeted: $targeted) { urls in
                        onDrop(urls, URL(fileURLWithPath: node.path, isDirectory: true))
                    })
            }
            .tag(node.id)
            .id(node.id)
        } else {
            label(icon: FileCategory(ext: node.row?.file.ext ?? "").systemImage, highlight: false)
                .modifier(DragSource(path: node.path, enabled: canEdit))
                .tag(node.id)
                .id(node.id)
        }
    }

    private func label(icon: String, highlight: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(highlight ? Theme.accent : Theme.textSecondary)
                .frame(width: 18)
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if node.isFolder {
                Text("\(node.fileCount.formatted()) Dateien")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            } else if let modified = node.row?.file.modified {
                Text(modified.formatted(date: .numeric, time: .omitted))
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
            Text(Format.bytes(node.size))
                .font(.caption).monospacedDigit().foregroundStyle(Theme.textSecondary)
                .frame(width: 70, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }
}

/// Zeile als Datei ziehbar machen (auch in den Finder).
private struct DragSource: ViewModifier {
    let path: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag { NSItemProvider(object: URL(fileURLWithPath: path) as NSURL) }
        } else {
            content
        }
    }
}

/// Ordnerzeile als Ablageziel.
private struct DropTarget: ViewModifier {
    let enabled: Bool
    @Binding var targeted: Bool
    let perform: ([URL]) -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: URL.self) { urls, _ in
                perform(urls.filter(\.isFileURL))
            } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}
