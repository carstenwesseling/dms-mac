import Charts
import SwiftUI

/// Übersicht über belegten und freien Speicher je Quelle und die Verteilung der Dateitypen.
struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @State private var sourceStats: [SourceStats] = []
    @State private var categoryStats: [CategoryStats] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                summary
                storage
                types
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .task { await load() }
        .onChange(of: state.progress.total) { Task { await load() } }
    }

    private var summary: some View {
        HStack(spacing: 16) {
            tile("Dateien im Index", state.progress.total.formatted())
            tile("Davon durchsuchbarer Text", state.progress.withText.formatted())
            tile("Indexierte Datenmenge", bytes(sourceStats.reduce(0) { $0 + $1.indexedBytes }))
            tile("Quellen", "\(sourceStats.count)")
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speicher je Quelle").font(.title3.bold())
            if sourceStats.isEmpty {
                Text("Noch keine Quellen eingebunden.").foregroundStyle(.secondary)
            }
            ForEach(sourceStats) { stats in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(stats.source.name, systemImage: stats.source.kind.systemImage).font(.headline)
                        Text(stats.source.kind.label).foregroundStyle(.secondary)
                        Spacer()
                        if let total = stats.volumeTotal, let free = stats.volumeFree {
                            Text("\(bytes(free)) frei von \(bytes(total))").foregroundStyle(.secondary)
                        } else {
                            Text("offline, Werte vom letzten Scan").foregroundStyle(.secondary)
                        }
                    }
                    if let total = stats.volumeTotal, let free = stats.volumeFree, total > 0 {
                        let used = Double(total - free) / Double(total)
                        let indexed = Double(stats.indexedBytes) / Double(total)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.35))
                                    .frame(width: geo.size.width * used)
                                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor)
                                    .frame(width: max(2, geo.size.width * min(indexed, used)))
                            }
                        }
                        .frame(height: 12)
                    }
                    Text("\(stats.fileCount.formatted()) Dateien, \(bytes(stats.indexedBytes)) in diesem Ordner")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            }
            HStack(spacing: 16) {
                legend(Color.accentColor, "Dieser Ordner")
                legend(Color.secondary.opacity(0.35), "Übriger belegter Platz")
                legend(Color.secondary.opacity(0.15), "Frei")
            }
            .font(.caption)
        }
    }

    private var types: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dateitypen nach Größe").font(.title3.bold())
            if categoryStats.isEmpty {
                Text("Noch keine Dateien erfasst.").foregroundStyle(.secondary)
            } else {
                Chart(categoryStats) { item in
                    BarMark(
                        x: .value("Größe (GB)", Double(item.bytes) / 1_000_000_000),
                        y: .value("Typ", item.category.rawValue)
                    )
                    .annotation(position: .trailing) {
                        Text("\(bytes(item.bytes)) · \(item.fileCount.formatted()) Dateien")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .chartXAxisLabel("Größe (GB)")
                .frame(height: CGFloat(categoryStats.count) * 34 + 30)
            }
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func load() async {
        let db = state.db
        let result = await Task.detached(priority: .userInitiated) {
            ((try? db.sourceStats()) ?? [], (try? db.categoryStats()) ?? [])
        }.value
        sourceStats = result.0
        categoryStats = result.1
    }
}
