import SwiftUI

/// Einstellungen und Status der lokalen KI, Vorschlag für die Ordnerstruktur.
struct AIView: View {
    @EnvironmentObject private var state: AppState
    @State private var settings = AISettings()
    @State private var modelName: String?
    @State private var checking = true
    @State private var counts = (summaries: 0, pendingDocs: 0, images: 0)
    @State private var structure: String?
    @State private var structureRunning = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Modell") {
                    if checking {
                        ProgressView().controlSize(.small)
                    } else if let modelName {
                        Label(modelName, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Kein Modell gefunden", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                if !checking && modelName == nil {
                    Text("So richtest du Ollama ein: Ollama von ollama.com installieren und starten, dann im Terminal `ollama pull \(settings.ollamaModel)` ausführen. Danach hier auf „Erneut prüfen“ klicken.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Zusammenfassungen", value: "\(counts.summaries) erstellt, \(counts.pendingDocs) offen")
                LabeledContent("Bilder erkannt", value: "\(counts.images)")
                Text("Alles läuft auf diesem Mac. Vorgeschlagene Tags findest du unter „Ablagevorschläge“.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Erneut prüfen") { Task { await refresh() } }
            }

            Section("Einstellungen") {
                Toggle("Dokumente automatisch zusammenfassen", isOn: $settings.enabled)
                TextField("Ollama-Modell", text: $settings.ollamaModel)
                TextField("Ollama-Adresse", text: $settings.ollamaURL)
                Text("Ist Apple Intelligence verfügbar, wird automatisch Apples Modell genutzt.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    if let message { Text(message).foregroundStyle(.secondary) }
                    Button("Sichern") { save() }
                }
            }

            Section("Ordnerstruktur") {
                Text("Die KI schaut sich deine vorhandenen Ordner an und schlägt eine flache Struktur nach Lebensbereich und Jahr vor. Es wird nichts verschoben.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Struktur vorschlagen") { suggest() }
                        .disabled(modelName == nil || structureRunning)
                    if structureRunning { ProgressView().controlSize(.small); Text("Das kann eine Minute dauern …").foregroundStyle(.secondary) }
                }
                if let structure {
                    Text(structure)
                        .textSelection(.enabled)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            settings = state.analyzer.settings()
            await refresh()
        }
    }

    private func refresh() async {
        checking = true
        let analyzer = state.analyzer
        let current = settings
        let result = await Task.detached {
            (await LocalModel.find(settings: current)?.name, analyzer.counts())
        }.value
        modelName = result.0
        counts = result.1
        checking = false
    }

    private func save() {
        do {
            try state.analyzer.save(settings)
            message = "Gespeichert"
            Task { await refresh() }
        } catch {
            message = "Konnte nicht speichern"
        }
    }

    private func suggest() {
        structureRunning = true
        let analyzer = state.analyzer
        Task {
            let result: Result<String, Error> = await Task.detached {
                do { return .success(try await analyzer.suggestStructure()) } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let text): structure = text
            case .failure(let error): structure = error.localizedDescription
            }
            structureRunning = false
        }
    }
}

/// Zusammenfassung und erkannte Bildinhalte in der Detailansicht.
struct AnalysisSection: View {
    @EnvironmentObject private var state: AppState
    let file: FileRecord
    @State private var analysis: Analyzer.Analysis?
    @State private var running = false
    @State private var message: String?

    private var isImage: Bool { TextExtractor.imageExtensions.contains(file.ext) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isImage ? "Bildinhalt" : "Zusammenfassung").font(.subheadline).foregroundStyle(.secondary)
            if let analysis {
                if let summary = analysis.summary {
                    Text(summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if !analysis.labels.isEmpty {
                    Text(analysis.labels.joined(separator: ", "))
                }
                if analysis.summary == nil && analysis.labels.isEmpty {
                    Text(analysis.model == "fehler" ? "Die KI konnte diese Datei nicht auswerten." : "Nichts erkannt.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                Text(isImage ? "Wird noch erkannt" : "Noch keine Zusammenfassung").font(.caption).foregroundStyle(.tertiary)
            }
            if !isImage && file.textState == .done {
                HStack {
                    Button(analysis?.summary == nil ? "Jetzt zusammenfassen" : "Neu zusammenfassen") { summarize() }
                        .disabled(running)
                    if running { ProgressView().controlSize(.small) }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: file.id) {
            message = nil
            analysis = file.id.flatMap { state.analyzer.analysis(fileId: $0) }
        }
    }

    private func summarize() {
        running = true
        message = nil
        let analyzer = state.analyzer
        let file = self.file
        Task {
            let result: Result<Void, Error> = await Task.detached {
                do { try await analyzer.summarize(file); return .success(()) } catch { return .failure(error) }
            }.value
            if case .failure(let error) = result { message = error.localizedDescription }
            analysis = file.id.flatMap { analyzer.analysis(fileId: $0) }
            running = false
        }
    }
}
