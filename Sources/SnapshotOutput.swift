import Foundation

enum SnapshotOutput {
    static func lines(for report: UsageReport, at date: Date = .now) -> [String] {
        UsageLimit.allCases.enumerated().flatMap { index, limit -> [String] in
            guard let snapshot = report[limit] else { return [] }
            return [
                "limit_\(index)_time_remaining=\(snapshot.timeRemainingPercent(at: date))",
                "limit_\(index)_usage_remaining=\(snapshot.usageRemainingPercent)",
                "limit_\(index)_resets_at=\(Int(snapshot.resetsAt.timeIntervalSince1970))",
            ]
        }
    }
}
