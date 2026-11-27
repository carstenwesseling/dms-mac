import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List(selection: $state.sidebar) {
            Section("Übersicht") {
                NavLabel("Dashboard", systemImage: "chart.pie").tag(SidebarItem.dashboard)
                NavLabel("Alle Dateien", systemImage: "doc.on.doc").tag(SidebarItem.allFiles)
            }

            Section("Ordnen") {
                NavLabel("Ablagevorschläge", systemImage: "tray.and.arrow.down").tag(SidebarItem.suggestions)
                NavLabel("Dubletten", systemImage: "doc.on.doc.fill").tag(SidebarItem.duplicates)
                NavLabel("Regeln", systemImage: "list.bullet.rectangle").tag(SidebarItem.rules)
                NavLabel("Protokoll", systemImage: "clock.arrow.circlepath").tag(SidebarItem.log)
            }

            Section("Dateitypen") {
                ForEach(FileCategory.allCases, id: \.self) { category in
                    NavLabel(category.rawValue, systemImage: category.systemImage)
                        .tag(SidebarItem.category(category))
                }
            }

            Section("Quellen") {
                ForEach(state.sources) { source in
                    if let id = source.id {
                        HStack {
                            NavLabel(source.name, systemImage: source.kind.systemImage)
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
                            Toggle("Versionen sichern", isOn: Binding(
                                get: { source.versioning },
                                set: { state.setVersioning(source, $0) }
                            ))
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
                    NavLabel("Ordner hinzufügen …", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            if !state.tags.isEmpty {
                Section("Tags") {
                    ForEach(state.tags) { tag in
                        if let id = tag.id {
                            NavLabel(tag.name, systemImage: "tag").tag(SidebarItem.tag(id))
                        }
                    }
                }
            }

            Section("Einstellungen") {
                NavLabel("Lokale KI", systemImage: "sparkles").tag(SidebarItem.ai)
                NavLabel("Ablage und Versionen", systemImage: "externaldrive.badge.timemachine").tag(SidebarItem.storageSettings)
                NavLabel("Standard-Apps", systemImage: "app.badge.checkmark").tag(SidebarItem.defaultApps)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
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
