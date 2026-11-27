import Quartz
import SwiftUI

struct FileBrowserView: View {
    @EnvironmentObject private var state: AppState
    @State private var sortOrder = [KeyPathComparator(\FileRow.file.modified, order: .reverse)]
    @State private var userSorted = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                FilterBar()
                Divider()
                fileTable
            }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            FileDetailView(rows: state.selectedRows)
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 560, maxHeight: .infinity)
        }
        // Tabelle und Detail füllen den ganzen Bereich über der Statuszeile
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $state.query, placement: .toolbar, prompt: "Suchen, z. B. typ:pdf quelle:cawserver rechnung")
        .onChange(of: state.query) {
            userSorted = false
            state.search(debounce: true)
        }
        .onChange(of: sortOrder) { userSorted = true }
        .onChange(of: state.filterSourceId) { state.search() }
        .onChange(of: state.filterCategory) {
            state.filterExt = nil
            state.search()
        }
        .onChange(of: state.filterExt) { state.search() }
    }

    private var fileTable: some View {
        Table(sortedRows, selection: $state.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.file.name) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.file.name).lineLimit(1)
                    if let snippet = row.snippet {
                        Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .width(min: 200, ideal: 460)
            TableColumn("Quelle", value: \.sourceName)
                .width(min: 70, ideal: 110)
            TableColumn("Typ", value: \.file.ext) { row in
                Text(row.file.ext.uppercased())
            }
            .width(min: 40, ideal: 60)
            TableColumn("Größe", value: \.file.size) { row in
                Text(ByteCountFormatter.string(fromByteCount: row.file.size, countStyle: .file))
            }
            .width(min: 60, ideal: 80)
            TableColumn("Geändert", value: \.file.modified) { row in
                Text(row.file.modified.formatted(date: .numeric, time: .omitted))
            }
            .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            let rows = state.rows.filter { ids.contains($0.id) }
            Button("Öffnen") { rows.forEach(state.open) }
            Button("Im Finder zeigen") { state.reveal(rows) }
        } primaryAction: { ids in
            state.rows.filter { ids.contains($0.id) }.forEach(state.open)
        }
        .overlay {
            if state.rows.isEmpty {
                if state.sources.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine Ordner eingebunden", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Füge Ordner vom Mac, von CAWServer oder aus Google Drive hinzu. Die Dateien bleiben, wo sie sind.")
                    } actions: {
                        Button("Ordner hinzufügen …") { state.addSourceWithPanel() }
                    }
                } else {
                    ContentUnavailableView.search(text: state.query)
                }
            }
        }
    }

    private var sortedRows: [FileRow] {
        // Bei einer Suche bleibt die Trefferreihenfolge, solange nicht umsortiert wird
        if !state.query.isEmpty && !userSorted { return state.rows }
        return state.rows.sorted(using: sortOrder)
    }
}

// MARK: - Filterleiste

/// Gezielt nach Quelle, Typ und Dateiendung filtern. Im Suchfeld gehen auch „typ:pdf“ und „quelle:cawserver“.
struct FilterBar: View {
    @EnvironmentObject private var state: AppState
    @State private var extensions: [(ext: String, count: Int)] = []

    private var sidebarFixesSource: Bool {
        if case .source = state.sidebar { return true } else { return false }
    }
    private var sidebarFixesCategory: Bool {
        if case .category = state.sidebar { return true } else { return false }
    }
    private var activeCategory: FileCategory? {
        if case .category(let c) = state.sidebar { return c }
        return state.filterCategory
    }
    private var visibleExtensions: [(ext: String, count: Int)] {
        guard let cat = activeCategory else { return extensions }
        return extensions.filter { FileCategory(ext: $0.ext) == cat }
    }

    var body: some View {
        HStack(spacing: 12) {
            Picker("Quelle", selection: $state.filterSourceId) {
                Text("Alle Quellen").tag(Int64?.none)
                Divider()
                ForEach(state.sources) { source in
                    Text(source.name).tag(source.id)
                }
            }
            .fixedSize()
            .disabled(sidebarFixesSource)

            Picker("Typ", selection: $state.filterCategory) {
                Text("Alle Typen").tag(FileCategory?.none)
                Divider()
                ForEach(FileCategory.allCases, id: \.self) { cat in
                    Text(cat.rawValue).tag(FileCategory?.some(cat))
                }
            }
            .fixedSize()
            .disabled(sidebarFixesCategory)

            Picker("Endung", selection: $state.filterExt) {
                Text("Alle").tag(String?.none)
                Divider()
                ForEach(visibleExtensions, id: \.ext) { item in
                    Text("\(item.ext.uppercased())  (\(item.count.formatted()))").tag(String?.some(item.ext))
                }
            }
            .fixedSize()

            if state.hasActiveFilter {
                Button("Filter zurücksetzen") { state.clearFilters() }
                    .buttonStyle(.link)
            }
            Spacer()
            Text("\(state.rows.count == 500 ? "500+" : state.rows.count.formatted()) Treffer")
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .help("Tipp: Im Suchfeld geht auch „typ:pdf rechnung“ oder „quelle:cawserver“.")
        .task(id: state.progress.total) {
            let db = state.db
            extensions = await Task.detached { (try? db.extensionCounts()) ?? [] }.value
        }
    }
}

// MARK: - Detailansicht

struct FileDetailView: View {
    @EnvironmentObject private var state: AppState
    let rows: [FileRow]
    @State private var newTag = ""
    @State private var fileTags: [Tag] = []

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView("Keine Datei ausgewählt", systemImage: "doc")
            } else if rows.count == 1, let row = rows.first {
                single(row)
            } else {
                multiple
            }
        }
        .onAppear(perform: loadTags)
        .onChange(of: rows.map(\.id)) { loadTags() }
    }

    private func single(_ row: FileRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if FileManager.default.fileExists(atPath: row.file.path) {
                QuickLookView(url: row.file.url)
                    .frame(minHeight: 260)
            } else {
                ContentUnavailableView("Datei gerade nicht erreichbar",
                                       systemImage: "wifi.slash",
                                       description: Text("Die Quelle ist offline. Name, Tags und Suchtext bleiben im Index."))
                    .frame(minHeight: 260)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(row.file.name).font(.headline).textSelection(.enabled)
                    HStack {
                        Button("Öffnen") { state.open(row) }
                        Button("Im Finder zeigen") { state.reveal([row]) }
                    }
                    tagEditor
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        info("Quelle", row.sourceName)
                        info("Pfad", row.file.path)
                        info("Größe", ByteCountFormatter.string(fromByteCount: row.file.size, countStyle: .file))
                        info("Geändert", row.file.modified.formatted(date: .long, time: .shortened))
                        if let created = row.file.created {
                            info("Erstellt", created.formatted(date: .long, time: .shortened))
                        }
                        if let used = row.file.lastUsed {
                            info("Zuletzt benutzt", used.formatted(date: .long, time: .shortened))
                        }
                        info("Inhalt", row.file.textState.label)
                    }
                    .font(.callout)
                    AnalysisSection(file: row.file)
                    VersionsSection(file: row.file)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var multiple: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(rows.count) Dateien ausgewählt").font(.headline)
            Text(ByteCountFormatter.string(fromByteCount: rows.reduce(0) { $0 + $1.file.size }, countStyle: .file))
                .foregroundStyle(.secondary)
            tagEditor
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").font(.subheadline).foregroundStyle(.secondary)
            FlowTags(tags: fileTags) { tag in
                state.removeTag(tag, from: rows)
                loadTags()
            }
            HStack {
                TextField("Tag hinzufügen", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTag)
                Button("Hinzufügen", action: addTag).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addTag() {
        state.addTag(newTag, to: rows)
        newTag = ""
        loadTags()
    }

    /// Zeigt die Tags, die alle ausgewählten Dateien gemeinsam haben.
    private func loadTags() {
        let ids = rows.compactMap(\.file.id)
        guard let first = ids.first else { fileTags = []; return }
        var common = (try? state.db.tags(forFile: first)) ?? []
        for id in ids.dropFirst() {
            let other = Set(((try? state.db.tags(forFile: id)) ?? []).compactMap(\.id))
            common.removeAll { !other.contains($0.id ?? -1) }
        }
        fileTags = common
    }

    @ViewBuilder
    private func info(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }
}

struct FlowTags: View {
    let tags: [Tag]
    let onRemove: (Tag) -> Void

    var body: some View {
        if tags.isEmpty {
            Text("Keine Tags").font(.caption).foregroundStyle(.tertiary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(tags) { tag in
                        HStack(spacing: 4) {
                            Text(tag.name)
                            Button {
                                onRemove(tag)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .help("Tag entfernen")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
            }
        }
    }
}

extension TextState {
    var label: String {
        switch self {
        case .pending: return "wird noch gelesen"
        case .done: return "Text erfasst, durchsuchbar"
        case .empty: return "kein Text gefunden"
        case .skipped: return "Dateityp wird nicht ausgelesen"
        case .cloudOnly: return "liegt nur online, wird nicht heruntergeladen"
        case .failed: return "konnte nicht gelesen werden"
        }
    }
}

// MARK: - QuickLook

struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL)?.filePathURL != url {
            view.previewItem = url as NSURL
        }
    }
}
