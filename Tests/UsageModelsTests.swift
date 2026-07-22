import Foundation

func usageModelTests() -> [TestCase] {
    let reset = Date(timeIntervalSince1970: 10_000)

    func snapshot(usedPercent: Int, windowDuration: TimeInterval = 1_000) -> UsageSnapshot {
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
        TestCase(name: "snapshot domain invariants hold at window boundaries") {
            let value = snapshot(usedPercent: 37)
            try expectEqual(value.usageRemainingPercent, 63)
            try expectEqual(value.timeRemainingFraction(at: reset.addingTimeInterval(-250)), 0.25)
            try expectEqual(value.timeRemainingPercent(at: reset.addingTimeInterval(-246)), 25)
            try expectEqual(value.timeRemainingFraction(at: reset.addingTimeInterval(1)), 0)
            try expectEqual(value.timeRemainingFraction(at: reset.addingTimeInterval(-2_000)), 1)
        },
        TestCase(name: "snapshot rejects malformed provider values") {
            try expectEqual(UsageSnapshot(usedPercent: -1, windowDuration: 1, resetsAt: reset), nil)
            try expectEqual(UsageSnapshot(usedPercent: 101, windowDuration: 1, resetsAt: reset), nil)
            try expectEqual(UsageSnapshot(usedPercent: 50, windowDuration: 0, resetsAt: reset), nil)
        },
        TestCase(name: "usage report requires at least one limit") {
            try expectEqual(UsageReport(), nil)
            guard let report = UsageReport(session: snapshot(usedPercent: 37)) else {
                throw TestFailure(description: "valid partial report was rejected")
            }
            try expectEqual(report.availableLimits, [.session])
            try expect(!report.isComplete, "a session-only report must not read as complete")
        },
        TestCase(name: "reading pace compares exact fractions before rounding") {
            let halfUsed = snapshot(usedPercent: 50)
            try expectEqual(halfUsed.reading(at: reset.addingTimeInterval(-500)).pace, .onPace)
            // The comparison is exact-fraction: 50.4% of the window left beats 50% usage left.
            try expectEqual(halfUsed.reading(at: reset.addingTimeInterval(-504)).pace, .behind)
            try expectEqual(halfUsed.reading(at: reset.addingTimeInterval(-250)).timeRemainingPercent, 25)
            try expectEqual(halfUsed.reading(at: reset.addingTimeInterval(-250)).usageRemainingFraction, 0.5)
        },
        TestCase(name: "critical threshold takes priority over pacing") {
            try expectEqual(snapshot(usedPercent: 86).reading(at: reset.addingTimeInterval(-1)).pace, .critical)
            try expectEqual(snapshot(usedPercent: 85).reading(at: reset.addingTimeInterval(-1)).pace, .onPace)
        },
        TestCase(name: "popover refresh throttle enforces a minimum interval") {
            let throttle = RefreshThrottle(maximumAge: 15 * 60)
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            try expect(
                throttle.shouldRefresh(lastSuccessfulRefreshAt: nil, now: now),
                "the first popover open must refresh"
            )
            try expect(
                !throttle.shouldRefresh(
                    lastSuccessfulRefreshAt: now.addingTimeInterval(-(15 * 60) + 1),
                    now: now
                ),
                "fresh data must not refetch"
            )
            try expect(
                throttle.shouldRefresh(
                    lastSuccessfulRefreshAt: now.addingTimeInterval(-(15 * 60)),
                    now: now
                ),
                "aged-out data must refetch"
            )
            try expect(
                throttle.shouldRefresh(lastSuccessfulRefreshAt: now.addingTimeInterval(1), now: now),
                "a clock rollback must refetch"
            )
        },
    ]
}
