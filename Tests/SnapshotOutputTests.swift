import Foundation

func snapshotOutputTests() -> [TestCase] {
    let reset = date("2026-07-21T05:00:00Z")
    let now = date("2026-07-21T04:00:00Z")

    func snapshot(usedPercent: Int, windowDuration: TimeInterval) -> UsageSnapshot {
        guard
            let snapshot = UsageSnapshot(
                usedPercent: usedPercent,
                windowDuration: windowDuration,
                resetsAt: reset
            )
        else {
            preconditionFailure("Invalid UsageSnapshot test fixture")
        }
        return snapshot
    }

    return [
        TestCase(name: "snapshot output preserves limit indexes") {
            guard let report = UsageReport(allModels: snapshot(usedPercent: 25, windowDuration: 10_000)) else {
                throw TestFailure(description: "valid weekly-only report was rejected")
            }
            try expectEqual(
                SnapshotOutput.lines(for: report, at: now),
                [
                    "limit_1_time_remaining=36",
                    "limit_1_usage_remaining=75",
                    "limit_1_resets_at=1784610000",
                ]
            )
        },
        TestCase(name: "snapshot output emits one triple per available limit") {
            guard
                let report = UsageReport(
                    session: snapshot(usedPercent: 12, windowDuration: 5 * 60 * 60),
                    allModels: snapshot(usedPercent: 34, windowDuration: 10_000),
                    fable: snapshot(usedPercent: 56, windowDuration: 10_000)
                )
            else {
                throw TestFailure(description: "valid complete report was rejected")
            }
            let lines = SnapshotOutput.lines(for: report, at: now)
            try expectEqual(lines.count, 9)
            for (limitIndex, offset) in [(0, 0), (1, 3), (2, 6)] {
                try expect(
                    lines[offset...(offset + 2)].allSatisfy { $0.hasPrefix("limit_\(limitIndex)_") },
                    "expected limit \(limitIndex) at line \(offset)"
                )
            }
        },
    ]
}

private func date(_ value: String) -> Date {
    guard let date = ISO8601DateFormatter().date(from: value) else {
        preconditionFailure("Invalid test date: \(value)")
    }
    return date
}
