import SwiftUI

/// Dateien als aufklappbare Ordnerstruktur oder als Gruppen gleichnamiger Dateien (z. B. ein Album).
struct FileTreeView: View {
    @EnvironmentObject private var state: AppState
    let mode: BrowseMode
    @State private var nodes: [FileNode] = []
    @State private var expanded: Set<String> = []
    @State private var nodeSelection: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $nodeSelection) {
                ForEach(nodes) { node in
                    NodeRow(node: node, expanded: $expanded)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { ids in
                let rows = rows(for: ids)
                if !rows.isEmpty {
                    Button("Öffnen") { rows.forEach(state.open) }
                    Button("Im Finder zeigen") { state.reveal(rows) }
                }
            } primaryAction: { ids in
                rows(for: ids).forEach(state.open)
            }
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
        }
    }

    private struct TreeKey: Equatable {
        var rows: [Int64]
        var mode: BrowseMode
    }

    private func rows(for ids: Set<String>) -> [FileRow] {
        let wanted = Set(ids.compactMap { $0.hasPrefix("f:") ? Int64($0.dropFirst(2)) : nil })
        return state.rows.filter { wanted.contains($0.id) }
    }

    private func rebuild() async {
        let rows = state.rows
        let sources = state.sources
        let mode = self.mode
        let built = await Task.detached(priority: .userInitiated) {
            mode == .groups ? FileTree.groups(rows) : FileTree.folders(rows, sources: sources)
        }.value
        nodes = built
        // Quellen aufgeklappt starten, damit man direkt die erste Ebene sieht
        if mode == .folders {
            expanded.formUnion(built.map(\.id))
        }
        nodeSelection = Set(state.selection.map { "f:\($0)" })
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

/// Eine Zeile: Ordner/Gruppe mit Aufklappen oder Datei.
private struct NodeRow: View {
    let node: FileNode
    @Binding var expanded: Set<String>

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(node.id) },
                set: { open in if open { expanded.insert(node.id) } else { expanded.remove(node.id) } }
            )) {
                ForEach(children) { child in
                    NodeRow(node: child, expanded: $expanded)
                }
            } label: {
                label(icon: node.id.hasPrefix("g:") ? "square.stack.3d.up" : "folder", highlight: true)
            }
            .tag(node.id)
            .id(node.id)
        } else {
            label(icon: FileCategory(ext: node.row?.file.ext ?? "").systemImage, highlight: false)
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
    }
}
