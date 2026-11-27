import Foundation
import GRDB

/// Kennzahlen für das Dashboard, die über Größe und Anzahl je Quelle hinausgehen.
struct DashboardInsights: Sendable {
    struct Month: Identifiable, Sendable {
        var start: Date
        var count: Int
        var id: Date { start }
    }

    var changedThisWeek = 0
    var changedLastWeek = 0
    var changedThisMonth = 0
    var changedLastMonth = 0
    /// Geänderte Dateien je Monat, die letzten 12 Monate (ältester zuerst)
    var months: [Month] = []
    var duplicateFiles = 0
    var duplicateBytes: Int64 = 0
    var openSuggestions = 0
    var summaries = 0
    /// Dateien je Nutzungsstufe: bis 60 Tage, bis 6 Monate, älter
    var tierCounts: [Int] = [0, 0, 0]
    var macTotal: Int64?
    var macFree: Int64?

    static func change(_ now: Int, _ before: Int) -> Double? {
        before > 0 ? Double(now - before) / Double(before) : nil
    }
}

extension AppDatabase {
    func dashboardInsights(now: Date = Date(), settings: StorageSettings = StorageSettings()) throws -> DashboardInsights {
        let cal = Calendar.current
        let day: TimeInterval = 86_400
        let weekAgo = now.addingTimeInterval(-7 * day)
        let twoWeeksAgo = now.addingTimeInterval(-14 * day)
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let lastMonthStart = cal.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
        let firstMonth = cal.date(byAdding: .month, value: -11, to: monthStart) ?? monthStart
        let hot = now.addingTimeInterval(-Double(settings.macDays) * day)
        let warm = now.addingTimeInterval(-Double(settings.driveDays) * day)

        var result = try reader.read { db -> DashboardInsights in
            var r = DashboardInsights()
            func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
                try Int.fetchOne(db, sql: sql, arguments: args) ?? 0
            }
            r.changedThisWeek = try count("SELECT COUNT(*) FROM file WHERE modified >= ?", [weekAgo])
            r.changedLastWeek = try count("SELECT COUNT(*) FROM file WHERE modified >= ? AND modified < ?", [twoWeeksAgo, weekAgo])
            r.changedThisMonth = try count("SELECT COUNT(*) FROM file WHERE modified >= ?", [monthStart])
            r.changedLastMonth = try count("SELECT COUNT(*) FROM file WHERE modified >= ? AND modified < ?", [lastMonthStart, monthStart])

            var byMonth: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT strftime('%Y-%m', modified, 'localtime') AS m, COUNT(*) AS n FROM file
                WHERE modified >= ? GROUP BY m
                """, arguments: [firstMonth]) {
                if let m: String = row["m"] { byMonth[m] = row["n"] }
            }
            let keyFormat = DateFormatter()
            keyFormat.dateFormat = "yyyy-MM"
            r.months = (0..<12).compactMap { i in
                guard let start = cal.date(byAdding: .month, value: i, to: firstMonth) else { return nil }
                return DashboardInsights.Month(start: start, count: byMonth[keyFormat.string(from: start)] ?? 0)
            }

            if let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(n - 1), 0) AS files, COALESCE(SUM((n - 1) * size), 0) AS bytes FROM (
                    SELECT COUNT(*) AS n, MAX(size) AS size FROM file
                    WHERE contentHash IS NOT NULL GROUP BY contentHash HAVING n > 1)
                """) {
                r.duplicateFiles = row["files"]
                r.duplicateBytes = row["bytes"]
            }
            r.openSuggestions = try count("SELECT COUNT(*) FROM suggestion WHERE status = 'open'")
            r.summaries = try count("SELECT COUNT(*) FROM analysis WHERE summary IS NOT NULL")

            // Zuletzt benutzt, sonst geändert
            let used = "COALESCE(lastUsed, modified)"
            r.tierCounts = [
                try count("SELECT COUNT(*) FROM file WHERE \(used) >= ?", [hot]),
                try count("SELECT COUNT(*) FROM file WHERE \(used) < ? AND \(used) >= ?", [hot, warm]),
                try count("SELECT COUNT(*) FROM file WHERE \(used) < ?", [warm]),
            ]
            return r
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            result.macTotal = values.volumeTotalCapacity.map(Int64.init)
            result.macFree = values.volumeAvailableCapacityForImportantUsage
        }
        return result
    }
}
