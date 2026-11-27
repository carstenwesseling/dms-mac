import SwiftUI

/// Einstellungen: Stand der Datenerfassung und des Taggings, beides lässt sich neu starten.
struct ProcessingView: View {
    @EnvironmentObject private var state: AppState
    @State private var stats = ProcessingStats()
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { activity(state.lastCaptureWork, open: stats.textPending) }
                LabeledContent("Dateien im Index", value: stats.total.formatted())
                LabeledContent("Text noch offen", value: stats.textPending.formatted())
                LabeledContent("Nicht lesbar", value: "\(stats.textFailed.formatted()) Texte, \(stats.hashFailed.formatted()) Prüfsummen")
                Text("Liest alle Quellen neu ein, nimmt neue und geänderte Dateien auf und versucht Dateien erneut, die nicht gelesen werden konnten. Es wird nichts verschoben oder gelöscht.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Datenerfassung neu starten") {
                    state.restartCapture()
                    message = state.status
                    reload()
                }
            } header: {
                Text("Datenerfassung")
            }

            Section {
                LabeledContent("Status") { activity(state.lastTaggingWork, open: stats.imagesPending + stats.docsPending) }
                LabeledContent("Bilder", value: "\(stats.imagesTagged.formatted()) getaggt, \(stats.imagesPending.formatted()) offen")
                LabeledContent("Dokumente", value: "\(stats.docsDone.formatted()) zusammengefasst, \(stats.docsPending.formatted()) offen")
                LabeledContent("Fehlgeschlagen", value: stats.aiFailed.formatted())
                Text("Startet die lokale KI neu und versucht fehlgeschlagene Dateien noch einmal. Vergebene Tags und fertige Zusammenfassungen bleiben erhalten. Für Tags muss Ollama laufen (siehe „Lokale KI“).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Tagging neu starten") {
                    state.restartTagging()
                    message = state.status
                    reload()
                }
            } header: {
                Text("Tagging")
            }

            if let message {
                Text(message).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            // Zahlen alle 5 Sekunden auffrischen, solange die Seite offen ist
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func reload() {
        let db = state.db
        Task {
            if let s = await Task.detached(operation: { try? db.processingStats() }).value, s != stats { stats = s }
        }
    }

    @ViewBuilder
    private func activity(_ last: Date?, open: Int) -> some View {
        if let last, last.timeIntervalSinceNow > -90 {
            Label("läuft", systemImage: "circle.fill").foregroundStyle(Theme.positive)
        } else if open > 0 {
            Label("wartet (\(open.formatted()) offen)", systemImage: "pause.circle").foregroundStyle(.orange)
        } else {
            Label("fertig", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        }
    }
}
