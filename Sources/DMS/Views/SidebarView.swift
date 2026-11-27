import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List(selection: $state.sidebar) {
            Section("Übersicht") {
                Label("Dashboard", systemImage: "chart.pie").tag(SidebarItem.dashboard)
                Label("Alle Dateien", systemImage: "doc.on.doc").tag(SidebarItem.allFiles)
            }

            Section("Dateitypen") {
                ForEach(FileCategory.allCases, id: \.self) { category in
                    Label(category.rawValue, systemImage: category.systemImage)
                        .tag(SidebarItem.category(category))
                }
            }

            Section("Quellen") {
                ForEach(state.sources) { source in
                    if let id = source.id {
                        HStack {
                            Label(source.name, systemImage: source.kind.systemImage)
                            Spacer()
                            if !source.isReachable {
                                Text("offline").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(SidebarItem.source(id))
                        .help(source.path)
                        .contextMenu {
                            Button("Neu scannen") { state.scan(source) }
                            Button("Im Finder zeigen") { NSWorkspace.shared.open(source.url) }
                            Divider()
                            Button("Quelle entfernen (Dateien bleiben erhalten)", role: .destructive) {
                                state.removeSource(source)
                            }
                        }
                    }
                }
                Button {
                    state.addSourceWithPanel()
                } label: {
                    Label("Ordner hinzufügen …", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            if !state.tags.isEmpty {
                Section("Tags") {
                    ForEach(state.tags) { tag in
                        if let id = tag.id {
                            Label(tag.name, systemImage: "tag").tag(SidebarItem.tag(id))
                        }
                    }
                }
            }

            Section("Einstellungen") {
                Label("Standard-Apps", systemImage: "app.badge.checkmark").tag(SidebarItem.defaultApps)
            }
        }
        .listStyle(.sidebar)
    }
}

extension FileCategory {
    var systemImage: String {
        switch self {
        case .dokumente: return "doc.text"
        case .tabellen: return "tablecells"
        case .praesentationen: return "rectangle.on.rectangle"
        case .bilder: return "photo"
        case .videos: return "film"
        case .audio: return "waveform"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archive: return "archivebox"
        case .sonstige: return "questionmark.folder"
        }
    }
}
