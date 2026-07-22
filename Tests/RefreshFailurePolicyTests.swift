import Foundation

func refreshFailurePolicyTests() -> [TestCase] {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func report(resetsAt: Date) -> UsageReport {
        guard
            let snapshot = UsageSnapshot(
                usedPercent: 20,
                windowDuration: 5 * 60 * 60,
                resetsAt: resetsAt
            ),
            let report = UsageReport(session: snapshot)
        else {
            preconditionFailure("Invalid refresh-policy test fixture")
        }
        return report
    }

    return [
        TestCase(name: "transient failures preserve an explicitly stale report") {
            try expect(
                RefreshFailurePolicy.preservesLastReport(for: ClaudeUsageClientError.timedOut),
                "expected timeout preservation"
            )
            try expect(
                RefreshFailurePolicy.preservesLastReport(for: ClaudeUsageClientError.launchFailed("exit 3")),
                "expected launch-failure preservation"
            )
            try expect(
                RefreshFailurePolicy.preservesLastReport(for: ClaudeUsageClientError.usageUnavailable),
                "expected schema-change preservation"
            )
        },
        TestCase(name: "missing installations invalidate the report") {
            try expect(
                !RefreshFailurePolicy.preservesLastReport(for: ClaudeUsageClientError.executableNotFound),
                "expected a missing executable to clear the gauge"
            )
            try expect(
                !RefreshFailurePolicy.preservesLastReport(for: ClaudeUsageClientError.helperNotFound),
                "expected a missing helper to clear the gauge"
            )
            try expect(
                !RefreshFailurePolicy.preservesLastReport(for: CocoaError(.fileNoSuchFile)),
                "expected an unclassified error to clear the gauge"
            )
        },
        TestCase(name: "stale reports expire with their last usage window") {
            let active = report(resetsAt: now.addingTimeInterval(60))
            try expect(active.hasUnexpiredUsage(at: now), "expected an active window to be unexpired")
            try expect(
                !active.hasUnexpiredUsage(at: now.addingTimeInterval(60)),
                "expected the window to expire at its reset"
            )
            try expect(
                RefreshFailurePolicy.preservesLastReport(
                    for: ClaudeUsageClientError.timedOut,
                    report: active,
                    at: now
                ),
                "expected an active stale window to remain visible"
            )
            try expect(
                !RefreshFailurePolicy.preservesLastReport(
                    for: ClaudeUsageClientError.timedOut,
                    report: active,
                    at: now.addingTimeInterval(60)
                ),
                "expected an expired stale window to clear"
            )
        },
    ]
}
