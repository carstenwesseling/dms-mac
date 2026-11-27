import AppKit
import SwiftUI

// MARK: - Ablagevorschläge

struct SuggestionsView: View {
    @EnvironmentObject private var state: AppState
    @State private var rows: [SuggestionRow] = []
    @State private var selection: Set<Int64> = []
    @State private var showDone = false
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ablagevorschläge").font(.title3.bold())
                Text("Nichts wird verschoben, bevor du es freigibst. Freigegebene Vorschläge werden kopiert, geprüft und erst dann am alten Ort in den Papierkorb gelegt. Alles lässt sich im Protokoll rückgängig machen.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Vorschläge aktualisieren") {
                        state.planSuggestions()
                        Task { try? await Task.sleep(for: .seconds(2)); load() }
                    }
                    Button("Ausgewählte ausführen (\(selection.count))") { accept(Array(selection)) }
                        .disabled(selection.isEmpty || working)
                        .keyboardShortcut(.defaultAction)
                    Button("Ablehnen") { reject(Array(selection)) }
                        .disabled(selection.isEmpty)
                    Spacer()
                    Toggle("Erledigte und wartende zeigen", isOn: $showDone)
                }
            }
            .padding(20)

            Table(rows, selection: $selection) {
                TableColumn("Datei") { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.file.name).lineLimit(1)
                        Text(row.file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 200, ideal: 300)
                TableColumn("Vorschlag") { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(describe(row.suggestion)).lineLimit(2).truncationMode(.middle)
                        Text(row.suggestion.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .width(min: 220, ideal: 360)
                TableColumn("Status") { row in
                    VStack(alignment: .leading) {
                        Text(row.suggestion.status.label)
                        if let detail = row.suggestion.detail {
                            Text(detail).font(.caption).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                }
                .width(min: 90, ideal: 130)
            }
            .contextMenu(forSelectionType: Int64.self) { ids in
                Button("Ausführen") { accept(Array(ids)) }
                Button("Ablehnen") { reject(Array(ids)) }
                Button("Wieder öffnen") { reopen(Array(ids)) }
                Button("Datei im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting(rows.filter { ids.contains($0.id) }.map(\.file.url))
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("Keine offenen Vorschläge", systemImage: "checkmark.circle",
                                           description: Text("Lege unter „Ablage und Versionen“ die Ablageziele fest und klicke auf „Vorschläge aktualisieren“."))
                }
            }
        }
        .task { load() }
        .onChange(of: showDone) { load() }
    }

    private func describe(_ s: Suggestion) -> String {
        switch s.kind {
        case .move: return "Verschieben nach \(s.target)"
        case .tag: return "Tag „\(s.target)“ setzen"
        case .trashDuplicate: return "Dublette in den Papierkorb"
        }
    }

    private func load() {
        let statuses: [SuggestionStatus] = showDone ? [.open, .queued, .failed, .done] : [.open, .queued, .failed]
        rows = (try? state.organizer.suggestions(status: statuses)) ?? []
        selection = selection.intersection(Set(rows.map(\.id)))
    }

    private func accept(_ ids: [Int64]) {
        working = true
        try? state.organizer.setStatus(ids, .queued)
        let organizer = state.organizer
        Task {
            await Task.detached(priority: .userInitiated) { _ = organizer.processQueue() }.value
            working = false
            selection = []
            load()
            state.search()
        }
    }

    private func reject(_ ids: [Int64]) {
        try? state.organizer.setStatus(ids, .rejected)
        selection = []
        load()
    }

    private func reopen(_ ids: [Int64]) {
        try? state.organizer.setStatus(ids, .open)
        load()
    }
}

// MARK: - Dubletten

struct DuplicatesView: View {
    @EnvironmentObject private var state: AppState
    @State private var groups: [DuplicateGroup] = []
    @State private var marked: Set<Int64> = []
    @State private var confirm = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Dubletten").font(.title3.bold())
                Text("Gleicher Inhalt in mehreren Ordnern, über alle Quellen. Vorgeschlagen wird, die Kopie am passenden Ablageort zu behalten. Markierte Kopien gehen in den Papierkorb und lassen sich im Protokoll zurückholen.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("\(groups.count) Gruppen, \(ByteCountFormatter.string(fromByteCount: groups.reduce(0) { $0 + $1.wastedBytes }, countStyle: .file)) doppelt belegt")
                    Spacer()
                    Button("Empfehlung übernehmen") { markRecommended() }.disabled(groups.isEmpty)
                    Button("Markierte in den Papierkorb (\(marked.count))") { confirm = true }
                        .disabled(marked.isEmpty)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(20)

            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.files) { row in
                            HStack {
                                Toggle("", isOn: Binding(
                                    get: { marked.contains(row.id) },
                                    set: { on in toggle(row.id, in: group, on: on) }
                                ))
                                .labelsHidden()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.file.path).lineLimit(1).truncationMode(.middle)
                                    Text("\(row.sourceName) · geändert \(row.file.modified.formatted(date: .numeric, time: .omitted))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([row.file.url])
                                } label: { Image(systemName: "magnifyingglass") }
                                    .buttonStyle(.borderless)
                                    .help("Im Finder zeigen")
                            }
                        }
                    } header: {
                        Text("\(group.files.first?.file.name ?? "") · \(group.files.count) Kopien · je \(ByteCountFormatter.string(fromByteCount: group.files.first?.file.size ?? 0, countStyle: .file))")
                    }
                }
            }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView("Keine Dubletten gefunden", systemImage: "checkmark.circle",
                                           description: Text("Prüfsummen werden im Hintergrund berechnet. Schau nach dem ersten Scan noch einmal vorbei."))
                }
            }
        }
        .task { load() }
        .confirmationDialog("\(marked.count) Kopien in den Papierkorb legen?", isPresented: $confirm) {
            Button("In den Papierkorb", role: .destructive) { trash() }
        } message: {
            Text("Von jeder Gruppe bleibt mindestens eine Kopie erhalten. Du kannst das im Protokoll rückgängig machen.")
        }
    }

    private func load() {
        let organizer = state.organizer
        Task {
            groups = await Task.detached { (try? organizer.duplicateGroups()) ?? [] }.value
            marked = marked.intersection(Set(groups.flatMap { $0.files.map(\.id) }))
        }
    }

    /// Mindestens eine Kopie pro Gruppe bleibt unmarkiert.
    private func toggle(_ id: Int64, in group: DuplicateGroup, on: Bool) {
        if on {
            let others = group.files.map(\.id).filter { $0 != id }
            guard others.contains(where: { !marked.contains($0) }) else {
                message = "Mindestens eine Kopie muss erhalten bleiben."
                return
            }
            marked.insert(id)
        } else {
            marked.remove(id)
        }
    }

    private func markRecommended() {
        let settings = state.organizer.settings()
        var result: Set<Int64> = []
        for group in groups {
            let keep = Organizer.recommendedKeep(group, sources: state.sources, settings: settings) ?? group.files.first?.id
            for row in group.files where row.id != keep { result.insert(row.id) }
        }
        marked = result
    }

    private func trash() {
        let ids = Array(marked)
        let organizer = state.organizer
        Task {
            let errors = await Task.detached { organizer.trashDuplicates(ids) }.value
            message = errors.isEmpty ? "\(ids.count) Kopien in den Papierkorb gelegt." : errors.joined(separator: "\n")
            marked = []
            load()
            state.search()
        }
    }
}

// MARK: - Regeln

struct RulesView: View {
    @EnvironmentObject private var state: AppState
    @State private var rules: [Rule] = []
    @State private var editing: Rule?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Regeln und feste Ablageorte").font(.title3.bold())
                Text("Eine Regel setzt einen Tag und/oder legt einen festen Ablageort fest, z. B. „Inhalt enthält Steuer → Tag Steuer, Ablage /Volumes/CAWServer/Archiv/Steuer“. Feste Ablageorte haben Vorrang vor den Nutzungsstufen. Ohne „automatisch“ entstehen nur Vorschläge.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Neue Regel") {
                        editing = Rule(id: nil, name: "", field: .content, value: "", position: rules.count)
                    }
                    Button("Regeln jetzt anwenden") { state.planSuggestions() }
                }
            }
            .padding(20)

            List {
                ForEach(rules) { rule in
                    HStack(alignment: .top) {
                        Toggle("", isOn: Binding(
                            get: { rule.enabled },
                            set: { var r = rule; r.enabled = $0; try? state.organizer.save(r); load() }
                        ))
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name.isEmpty ? "Ohne Namen" : rule.name).bold()
                            Text(summary(rule)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if rule.automatic { Text("automatisch").font(.caption).padding(4).background(Capsule().fill(.orange.opacity(0.2))) }
                        Button("Bearbeiten") { editing = rule }
                        Button(role: .destructive) {
                            try? state.organizer.delete(rule)
                            load()
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
            .overlay {
                if rules.isEmpty {
                    ContentUnavailableView("Noch keine Regeln", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .task { load() }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { saved in
                try? state.organizer.save(saved)
                state.ensureIndexed(saved.targetPath)
                editing = nil
                load()
            } onCancel: {
                editing = nil
            }
        }
    }

    private func summary(_ rule: Rule) -> String {
        var parts = ["Wenn \(rule.field.label) „\(rule.value)“"]
        if let tag = rule.addTag, !tag.isEmpty { parts.append("Tag „\(tag)“") }
        if let target = rule.targetPath, !target.isEmpty { parts.append("Ablage: \(target)") }
        return parts.joined(separator: " → ")
    }

    private func load() {
        rules = (try? state.organizer.rules()) ?? []
    }
}

struct RuleEditor: View {
    @State var rule: Rule
    let onSave: (Rule) -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            TextField("Name", text: $rule.name)
            Picker("Bedingung", selection: $rule.field) {
                ForEach(RuleField.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            TextField("Wert", text: $rule.value, prompt: Text(placeholder))
            TextField("Tag setzen (optional)", text: Binding(
                get: { rule.addTag ?? "" },
                set: { rule.addTag = $0.isEmpty ? nil : $0 }
            ))
            HStack {
                TextField("Fester Ablageort (optional)", text: Binding(
                    get: { rule.targetPath ?? "" },
                    set: { rule.targetPath = $0.isEmpty ? nil : $0 }
                ))
                Button("Wählen …") {
                    if let path = FolderPicker.pick(message: "Fester Ablageort für diese Regel") { rule.targetPath = path }
                }
            }
            Toggle("Automatisch ausführen (ohne Rückfrage)", isOn: $rule.automatic)
            Toggle("Aktiv", isOn: $rule.enabled)
            HStack {
                Spacer()
                Button("Abbrechen", action: onCancel)
                Button("Sichern") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var placeholder: String {
        switch rule.field {
        case .name: return "z. B. Rechnung"
        case .content: return "z. B. Steuerbescheid"
        case .ext: return "z. B. pdf"
        case .tag: return "z. B. Finanzen"
        }
    }
}

enum FolderPicker {
    @MainActor
    static func pick(message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Auswählen"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: - Einstellungen für Ablage und Versionen

struct StorageSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var settings = StorageSettings()
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                Text("Wohin Dateien je nach Nutzung gehören. Diese Ordner werden automatisch in den Index aufgenommen.")
                    .foregroundStyle(.secondary)
                folderRow("Mac (genutzt in den letzten \(settings.macDays) Tagen)", \.macTarget, hint: "z. B. ~/Dokumente/Ablage")
                folderRow("Google Drive (genutzt in den letzten \(settings.driveDays) Tagen)", \.driveTarget, hint: "ein Ordner in Google Drive")
                folderRow("CAWServer (alles Ältere)", \.nasTarget, hint: "z. B. /Volumes/CAWServer/Archiv")
                Stepper("Mac: bis \(settings.macDays) Tage", value: $settings.macDays, in: 7...365, step: 1)
                Stepper("Google Drive: bis \(settings.driveDays) Tage", value: $settings.driveDays, in: settings.macDays...1095, step: 1)
            } header: {
                Text("Ablageziele und Nutzungsstufen")
            }

            Section {
                folderRow("Versionsordner", \.versionsFolder, hint: "z. B. /Volumes/CAWServer/DMS-Versionen")
                Stepper("Aufbewahren: \(settings.keepVersions) Versionen pro Datei", value: $settings.keepVersions, in: 1...100)
                Text("Versionen werden für Quellen gesichert, bei denen im Kontextmenü der Seitenleiste „Versionen sichern“ an ist (Dokumente, Tabellen, Präsentationen bis 100 MB). Ist CAWServer aus, wird die Sicherung nachgeholt, sobald es wieder erreichbar ist.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Versionen")
            }

            HStack {
                Spacer()
                if saved { Text("Gespeichert").foregroundStyle(.secondary) }
                Button("Sichern") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .task { settings = state.organizer.settings() }
        .onChange(of: settings) { saved = false }
    }

    private func folderRow(_ title: String, _ key: WritableKeyPath<StorageSettings, String?>, hint: String) -> some View {
        LabeledContent(title) {
            HStack {
                Text(settings[keyPath: key] ?? hint)
                    .foregroundStyle(settings[keyPath: key] == nil ? .tertiary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Wählen …") {
                    if let path = FolderPicker.pick(message: title) { settings[keyPath: key] = path }
                }
                if settings[keyPath: key] != nil {
                    Button { settings[keyPath: key] = nil } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private func save() {
        do {
            try state.organizer.save(settings)
            state.ensureIndexed(settings.macTarget)
            state.ensureIndexed(settings.driveTarget)
            state.ensureIndexed(settings.nasTarget)
            saved = true
        } catch {
            state.errorMessage = "Einstellungen konnten nicht gespeichert werden."
        }
    }
}

// MARK: - Protokoll

struct ActionLogView: View {
    @EnvironmentObject private var state: AppState
    @State private var entries: [ActionLogEntry] = []
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Protokoll").font(.title3.bold())
                Text("Alle Verschiebungen und gelöschten Dubletten. Rückgängig holt die Datei an ihren alten Ort zurück.")
                    .foregroundStyle(.secondary)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(20)

            Table(entries) {
                TableColumn("Zeit") { e in Text(e.at.formatted(date: .numeric, time: .shortened)) }
                    .width(min: 110, ideal: 130)
                TableColumn("Aktion") { e in Text(e.kind == "trash" ? "Papierkorb" : "Verschoben") }
                    .width(min: 80, ideal: 90)
                TableColumn("Von") { e in Text(e.fromPath).lineLimit(1).truncationMode(.middle) }
                TableColumn("Nach") { e in Text(e.toPath).lineLimit(1).truncationMode(.middle) }
                TableColumn("") { e in
                    if e.undone {
                        Text("rückgängig gemacht").foregroundStyle(.secondary)
                    } else {
                        Button("Rückgängig") { undo(e) }
                    }
                }
                .width(min: 110, ideal: 130)
            }
            .overlay {
                if entries.isEmpty { ContentUnavailableView("Noch keine Aktionen", systemImage: "clock") }
            }
        }
        .task { load() }
    }

    private func load() { entries = (try? state.organizer.log()) ?? [] }

    private func undo(_ entry: ActionLogEntry) {
        let organizer = state.organizer
        Task {
            let result = await Task.detached { Result { try organizer.undo(entry) } }.value
            switch result {
            case .success: message = "Rückgängig gemacht: \(URL(fileURLWithPath: entry.fromPath).lastPathComponent)"
            case .failure(let e): message = "Nicht möglich: \(e.localizedDescription)"
            }
            load()
            state.search()
        }
    }
}

// MARK: - Versionen in der Detailansicht

struct VersionsSection: View {
    @EnvironmentObject private var state: AppState
    let file: FileRecord
    @State private var versions: [FileVersion] = []
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Versionen").font(.subheadline).foregroundStyle(.secondary)
            if versions.isEmpty {
                Text("Keine gesicherten Versionen").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(versions) { v in
                HStack {
                    Text(v.at.formatted(date: .numeric, time: .shortened))
                    Text(ByteCountFormatter.string(fromByteCount: v.size, countStyle: .file)).foregroundStyle(.secondary)
                    Spacer()
                    if let copy = v.copyPath {
                        Button("Ansehen") { NSWorkspace.shared.open(URL(fileURLWithPath: copy)) }
                            .disabled(!FileOps.isReachable(copy))
                        Button("Als Kopie wiederherstellen") { restore(v) }
                            .disabled(!FileOps.isReachable(copy))
                    }
                }
                .font(.callout)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: file.path) { versions = (try? state.organizer.versions(of: file.path)) ?? [] }
    }

    private func restore(_ v: FileVersion) {
        do {
            let url = try state.organizer.restore(v)
            message = "Wiederhergestellt als \(url.lastPathComponent)"
        } catch {
            message = error.localizedDescription
        }
    }
}
