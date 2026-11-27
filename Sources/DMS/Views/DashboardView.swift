import Charts
import SwiftUI

/// Dashboard im dunklen Kartenstil: Aktivität, Platz pro Speicherort, Mac-Speicher, Dateitypen und Quellen.
struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @State private var sourceStats: [SourceStats] = []
    @State private var categoryStats: [CategoryStats] = []
    @State private var insights = DashboardInsights()
    @State private var selectedAngle: Int64?

    private let gap: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 1000
            ScrollView {
                VStack(spacing: gap) {
                    header
                    if wide {
                        HStack(spacing: gap) {
                            hero.frame(maxWidth: .infinity)
                                .layoutPriority(2)
                            places.frame(width: (geo.size.width - 56 - 2 * gap) / 3)
                        }
                        .frame(height: 310)
                        HStack(spacing: gap) {
                            macGauge
                            types
                            VStack(spacing: gap) { duplicates; searchable }
                        }
                        .frame(height: 250)
                    } else {
                        hero.frame(height: 310)
                        HStack(spacing: gap) { places; macGauge }.frame(height: 290)
                        HStack(spacing: gap) {
                            types
                            VStack(spacing: gap) { duplicates; searchable }
                        }
                        .frame(height: 250)
                    }
                    sourcesTable
                }
                .padding(28)
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
        .background(Theme.background)
        .task {
            // Regelmäßig aktualisieren, solange das Dashboard offen ist
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("Dashboard").font(.system(size: 26, weight: .medium)).foregroundStyle(.white)
            Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            Spacer()
            if state.progress.pending > 0 {
                Label("Text wird gelesen: noch \(state.progress.pending.formatted())", systemImage: "text.magnifyingglass")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: Aktivität

    private var hero: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 48) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Dateien im Index").font(.system(size: 17, weight: .medium))
                        BigNumber(value: state.progress.total.formatted(), size: 52)
                    }
                    delta("Diese Woche", insights.changedThisWeek, insights.changedLastWeek, "in der Vorwoche")
                    delta("Dieser Monat", insights.changedThisMonth, insights.changedLastMonth, "im Vormonat")
                    Spacer(minLength: 0)
                }
                .padding([.horizontal, .top], 24)

                Chart(insights.months) { month in
                    AreaMark(x: .value("Monat", month.start, unit: .month), y: .value("Geändert", month.count))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.55), Theme.accent.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Monat", month.start, unit: .month), y: .value("Geändert", month.count))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Theme.accentLight)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated), centered: false)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .padding(.top, 8)
            }
        }
        .drillDown("Alle Dateien zeigen, neueste zuerst") {
            state.clearFilters()
            state.browseMode = .list
            state.sidebar = .allFiles
        }
    }

    private func delta(_ title: String, _ now: Int, _ before: Int, _ beforeText: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(now.formatted()).font(.system(size: 30, weight: .light)).monospacedDigit()
                if let change = DashboardInsights.change(now, before) {
                    Text("\(change >= 0 ? "↑" : "↓") \(Format.percent(abs(change)))")
                        .font(.system(size: 12))
                        .foregroundStyle(change >= 0 ? Theme.positive : Theme.accentLight)
                }
            }
            Text("geändert, \(before.formatted()) \(beforeText)")
                .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: Platz pro Speicherort

    private struct PlaceSlice: Identifiable {
        var kind: SourceKind
        var bytes: Int64
        var id: String { kind.rawValue }
    }

    private var slices: [PlaceSlice] {
        SourceKind.allCases.compactMap { kind in
            let bytes = sourceStats.filter { $0.source.kind == kind }.reduce(Int64(0)) { $0 + $1.indexedBytes }
            return bytes > 0 ? PlaceSlice(kind: kind, bytes: bytes) : nil
        }
    }

    private func color(for kind: SourceKind) -> Color {
        switch kind {
        case .local: return Theme.accent
        case .nas: return Color(red: 1.0, green: 0.7, blue: 0.48)
        case .googleDrive: return Color(red: 0.55, green: 0.16, blue: 0.04)
        }
    }

    private var places: some View {
        Card(title: "Platz pro Speicherort") {
            let total = slices.reduce(Int64(0)) { $0 + $1.bytes }
            if slices.isEmpty {
                Text("Noch keine Quellen eingebunden.").foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 18) {
                    Chart(slices) { slice in
                        SectorMark(angle: .value("Größe", slice.bytes), innerRadius: .ratio(0.7), angularInset: 2)
                            .cornerRadius(3)
                            .foregroundStyle(color(for: slice.kind))
                    }
                    .chartAngleSelection(value: $selectedAngle)
                    .onChange(of: selectedAngle) {
                        guard let value = selectedAngle else { return }
                        var acc: Int64 = 0
                        for slice in slices {
                            acc += slice.bytes
                            if value <= acc { state.showFiles(kind: slice.kind); break }
                        }
                        selectedAngle = nil
                    }
                    .chartBackground { _ in
                        let parts = Format.bytesParts(total)
                        VStack(spacing: 0) {
                            Text(parts.0).font(.system(size: 24, weight: .thin)).foregroundStyle(.white)
                            Text("\(parts.1) belegt").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .frame(width: 160, height: 160)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(slices.sorted { $0.bytes > $1.bytes }) { slice in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3).fill(color(for: slice.kind)).frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(slice.kind == .nas ? "CAWServer" : slice.kind.label).font(.system(size: 13))
                                    Text(Format.bytes(slice.bytes)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer(minLength: 4)
                                Text(Format.percent(total > 0 ? Double(slice.bytes) / Double(total) : 0))
                                    .font(.system(size: 13, weight: .light)).monospacedDigit()
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                            }
                            .drillDown("Dateistruktur dieses Speicherorts öffnen") { state.showFiles(kind: slice.kind) }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: Mac-Speicher

    private var macGauge: some View {
        Card(title: "Mac-Speicher") {
            if let total = insights.macTotal, let free = insights.macFree, total > 0 {
                let used = Double(total - free) / Double(total)
                ZStack {
                    SegmentGauge(value: used)
                    VStack(spacing: 2) {
                        Text(Format.percent(used)).font(.system(size: 34, weight: .thin))
                        Text("\(Format.bytes(free)) frei von \(Format.bytes(total))")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    .offset(y: 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Nicht verfügbar").foregroundStyle(Theme.textSecondary)
            }
        }
        .drillDown("Dateien auf dem Mac als Ordnerstruktur zeigen") { state.showFiles(kind: .local) }
    }

    // MARK: Dateitypen

    private var types: some View {
        Card(title: "Dateitypen nach Größe") {
            let top = Array(categoryStats.prefix(5))
            let total = categoryStats.reduce(Int64(0)) { $0 + $1.bytes }
            let maxBytes = max(top.first?.bytes ?? 1, 1)
            VStack(spacing: 10) {
                ForEach(top) { item in
                    VStack(spacing: 5) {
                        HStack {
                            Text(item.category.rawValue).foregroundStyle(Color.white.opacity(0.8))
                            Spacer()
                            Text("\(Format.bytes(item.bytes)) · \(Format.percent(total > 0 ? Double(item.bytes) / Double(total) : 0))")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .font(.system(size: 12))
                        TickBar(fraction: Double(item.bytes) / Double(maxBytes))
                    }
                    .drillDown("\(item.category.rawValue) zeigen") { state.showCategory(item.category) }
                }
                if top.isEmpty {
                    Text("Noch keine Dateien erfasst.").foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    // MARK: Kleine Kennzahlen

    private var duplicates: some View {
        let parts = Format.bytesParts(insights.duplicateBytes)
        return stat("Dubletten", parts.0, "\(parts.1) doppelt", "\(insights.duplicateFiles.formatted()) Dateien")
            .drillDown("Dubletten ansehen") { state.sidebar = .duplicates }
    }

    private var searchable: some View {
        let total = max(state.progress.total, 1)
        let share = Double(state.progress.withText) / Double(total)
        return stat("Durchsuchbar", "\(Int((share * 100).rounded()))", "%", "\(state.progress.withText.formatted()) mit Text")
            .drillDown("Alle Dateien zeigen") {
                state.clearFilters()
                state.sidebar = .allFiles
            }
    }

    private func stat(_ title: String, _ value: String, _ unit: String, _ note: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.system(size: 14, weight: .medium))
            Spacer(minLength: 4)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 40, weight: .thin)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(unit).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 4)
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }

    // MARK: Quellen

    private var sourcesTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Speicherort").frame(maxWidth: .infinity, alignment: .leading)
                Text("Art").frame(width: 110, alignment: .leading)
                Text("Dateien").frame(width: 90, alignment: .trailing)
                Text("Indexiert").frame(width: 100, alignment: .trailing)
                Text("Frei").frame(width: 100, alignment: .trailing)
                Text("Status").frame(width: 100, alignment: .trailing)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .padding(.vertical, 10)

            ForEach(sourceStats) { stats in
                Divider().overlay(Theme.stroke)
                HStack {
                    HStack(spacing: 10) {
                        IconTile(systemName: stats.source.kind.systemImage, size: 26)
                        Text(stats.source.name)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(stats.source.kind.label).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
                    Text(stats.fileCount.formatted()).frame(width: 90, alignment: .trailing)
                    Text(Format.bytes(stats.indexedBytes)).frame(width: 100, alignment: .trailing)
                    Text(stats.volumeFree.map(Format.bytes) ?? "–").frame(width: 100, alignment: .trailing)
                    Group {
                        if stats.volumeTotal != nil {
                            Text(stats.source.kind == .googleDrive ? "streamt" : "verbunden")
                                .foregroundStyle(stats.source.kind == .googleDrive ? Theme.accentLight : Theme.positive)
                        } else {
                            Text("offline").foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(width: 100, alignment: .trailing)
                }
                .font(.system(size: 14))
                .monospacedDigit()
                .padding(.vertical, 9)
                .drillDown("\(stats.source.name) als Ordnerstruktur öffnen") {
                    if let id = stats.source.id { state.showFolders(sourceId: id) }
                }
            }
            if sourceStats.isEmpty {
                Text("Noch keine Quellen eingebunden.").foregroundStyle(Theme.textSecondary).padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 8)
        .cardBackground()
    }

    private func load() async {
        let db = state.db
        let storage = state.organizer.settings()
        let result = await Task.detached(priority: .userInitiated) {
            ((try? db.sourceStats()) ?? [], (try? db.categoryStats()) ?? [],
             (try? db.dashboardInsights(settings: storage)) ?? DashboardInsights())
        }.value
        sourceStats = result.0
        categoryStats = result.1
        insights = result.2
    }
}

// MARK: - Bausteine

/// Tacho aus einzelnen Segmenten, die von links unten über oben nach rechts unten laufen.
struct SegmentGauge: View {
    var value: Double
    var segments = 32

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height * 0.6)
            let outer = min(size.width / 2, size.height * 0.6) - 8
            let inner = outer * 0.8
            let start = 200.0, sweep = 220.0
            let filled = Int((value * Double(segments)).rounded())
            for i in 0..<segments {
                let angle = (start - Double(i) * sweep / Double(segments - 1)) * .pi / 180
                var path = Path()
                path.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y - inner * sin(angle)))
                path.addLine(to: CGPoint(x: center.x + outer * cos(angle), y: center.y - outer * sin(angle)))
                let color = i < filled ? Theme.accent : Color.white.opacity(0.14)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(4, outer * 0.08), lineCap: .round))
            }
        }
    }
}

/// Balken über einer feinen Strichskala, Verlauf von dunkel nach Orange.
struct TickBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    var x: CGFloat = 0
                    while x < size.width {
                        context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                                     with: .color(.white.opacity(0.13)))
                        x += 6
                    }
                }
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Theme.accentDeep.opacity(0.6), Theme.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 10)
    }
}
