import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Verwaltung: Welcher Dateityp wird mit welcher App geöffnet?
/// Änderungen gelten systemweit, wie im Finder unter „Informationen > Öffnen mit“.
struct DefaultAppsView: View {
    @EnvironmentObject private var state: AppState
    @State private var entries: [Entry] = []
    @State private var filter = ""
    @State private var message: String?

    struct Entry: Identifiable {
        var ext: String
        var count: Int
        var type: UTType
        var current: URL?
        var candidates: [URL]
        var id: String { ext }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Standard-Apps pro Dateityp").font(.title3.bold())
                Text("Gezeigt werden die Dateitypen aus deinen Quellen. macOS fragt beim Ändern eventuell einmal nach.")
                    .foregroundStyle(.secondary)
                TextField("Dateityp filtern, z. B. pdf", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Table(filtered) {
                TableColumn("Typ") { entry in
                    VStack(alignment: .leading) {
                        Text(".\(entry.ext)").bold()
                        Text(entry.type.localizedDescription ?? entry.type.identifier)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .width(min: 160, ideal: 220)
                TableColumn("Dateien") { entry in
                    Text(entry.count.formatted())
                }
                .width(60)
                TableColumn("Öffnen mit") { entry in
                    Picker("", selection: Binding(
                        get: { entry.current },
                        set: { newValue in if let newValue { setDefault(newValue, for: entry) } }
                    )) {
                        if entry.current == nil {
                            Text("Keine App").tag(URL?.none)
                        }
                        ForEach(entry.candidates, id: \.self) { app in
                            Text(appName(app)).tag(Optional(app))
                        }
                    }
                    .labelsHidden()
                }
            }
        }
        .task { load() }
    }

    private var filtered: [Entry] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ".", with: "")
        return f.isEmpty ? entries : entries.filter { $0.ext.contains(f) }
    }

    private func load() {
        let counts = (try? state.db.extensionCounts()) ?? []
        entries = counts.compactMap { item in
            guard let type = UTType(filenameExtension: item.ext), !type.isDynamic else { return nil }
            let workspace = NSWorkspace.shared
            var candidates = workspace.urlsForApplications(toOpen: type)
            let current = workspace.urlForApplication(toOpen: type)
            if let current, !candidates.contains(current) { candidates.insert(current, at: 0) }
            // gleiche App nicht doppelt (z. B. aus mehreren Ordnern)
            var seen = Set<String>()
            candidates = candidates.filter { seen.insert(appName($0)).inserted }
            guard !candidates.isEmpty else { return nil }
            return Entry(ext: item.ext, count: item.count, type: type, current: current, candidates: candidates)
        }
    }

    private func setDefault(_ app: URL, for entry: Entry) {
        Task {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: entry.type)
                message = ".\(entry.ext) öffnet jetzt mit \(appName(app))."
            } catch {
                message = "Konnte .\(entry.ext) nicht ändern: \(error.localizedDescription)"
            }
            load()
        }
    }

    private func appName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
