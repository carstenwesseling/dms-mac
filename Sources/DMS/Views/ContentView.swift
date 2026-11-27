import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            VStack(spacing: 0) {
                Group {
                switch state.sidebar {
                case .dashboard:
                    DashboardView()
                case .defaultApps:
                    DefaultAppsView()
                case .duplicates:
                    DuplicatesView()
                case .suggestions:
                    SuggestionsView()
                case .rules:
                    RulesView()
                case .storageSettings:
                    StorageSettingsView()
                case .log:
                    ActionLogView()
                case .ai:
                    AIView()
                default:
                    FileBrowserView()
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                StatusBar()
            }
            .background(Theme.background)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    state.addSourceWithPanel()
                } label: {
                    Label("Ordner hinzufügen", systemImage: "folder.badge.plus")
                }
                .help("Ordner auf dem Mac, auf CAWServer oder in Google Drive einbinden")
                Button {
                    state.scanAll()
                } label: {
                    Label("Neu scannen", systemImage: "arrow.clockwise")
                }
                .help("Alle Quellen neu scannen")
            }
        }
        .onChange(of: state.sidebar) { state.search() }
        .alert("Hinweis", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Text("\(state.progress.total.formatted()) Dateien im Index")
            if state.progress.pending > 0 {
                ProgressView().controlSize(.small)
                Text("Text wird gelesen: noch \(state.progress.pending.formatted())")
            }
            Spacer()
            Text(state.status).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
