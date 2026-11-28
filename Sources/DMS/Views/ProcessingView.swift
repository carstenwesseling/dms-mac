import SwiftUI

/// Einstellungen: Stand der Datenerfassung und des Taggings, beides lässt sich neu starten.
struct ProcessingView: View {
    @EnvironmentObject private var state: AppState
    @State private var stats = ProcessingStats()
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { ActivityBadge(last: state.lastCaptureWork, open: stats.textPending) }
                LabeledContent("Dateien im Index", value: stats.total.formatted())
                LabeledContent("Text noch offen", value: stats.textPending.formatted())
                LabeledContent("Nicht lesbar", value: "\(stats.textFailed.formatted()) Texte, \(stats.hashFailed.formatted()) Prüfsummen")
                Text("Liest alle Quellen neu ein, nimmt neue und geänderte Dateien auf und versucht Dateien erneut, die nicht gelesen werden konnten. Es wird nichts verschoben oder gelöscht.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Mac während der Erfassung wach halten", isOn: $state.keepAwake)
                Text("Verhindert den Ruhezustand, solange noch Dateien offen sind. Der Bildschirm geht trotzdem aus. Im Ruhezustand trennt macOS das NAS; die App verbindet es danach automatisch wieder.")
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
                ForEach(CaptureSettings.categories, id: \.self) { category in
                    Toggle(CaptureSettings.label(category), isOn: Binding(
                        get: { CaptureSettings.isEnabled(category) },
                        set: { on in
                            state.setCapture(category, enabled: on)
                            message = state.status
                            reload()
                        }
                    ))
                }
                ForEach(CaptureSettings.mediaCategories, id: \.self) { category in
                    Toggle(CaptureSettings.label(category) + " (für die Dublettensuche ganz lesen)", isOn: Binding(
                        get: { CaptureSettings.isEnabled(category) },
                        set: { on in
                            CaptureSettings.setEnabled(category, on)
                            message = "\(CaptureSettings.label(category)): " + (on ? "werden wieder gelesen" : "werden nicht mehr gelesen")
                            state.objectWillChange.send()
                        }
                    ))
                }
                Text("Abgeschaltete Typen bleiben im Index und sind über Name, Ordner und Tags auffindbar, ihr Inhalt wird aber nicht gelesen. Ohne Bilder entfällt auch das automatische Taggen von Fotos. Ohne Videos, Audio oder Archive werden diese nicht mehr als Dubletten erkannt. Einschalten holt die Erfassung nach.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Was erfasst wird")
            }

            Section {
                LabeledContent("Status") { ActivityBadge(last: state.lastTaggingWork, open: stats.imagesPending + stats.docsPending) }
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
}

/// „läuft“, „wartet“ oder „fertig“, je nachdem wann zuletzt etwas erledigt wurde.
struct ActivityBadge: View {
    let last: Date?
    let open: Int

    var body: some View {
        if let last, last.timeIntervalSinceNow > -90 {
            Label("läuft", systemImage: "circle.fill").foregroundStyle(Theme.positive)
        } else if open > 0 {
            Label("wartet", systemImage: "pause.circle").foregroundStyle(.orange)
        } else {
            Label("fertig", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        }
    }
}
