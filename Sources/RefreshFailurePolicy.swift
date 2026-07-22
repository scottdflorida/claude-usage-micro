import Foundation

/// Decides whether a failed refresh keeps the last report visible as stale data.
enum RefreshFailurePolicy {
    static func preservesLastReport(
        for error: any Error,
        report: UsageReport,
        at date: Date = .now
    ) -> Bool {
        report.hasUnexpiredUsage(at: date) && preservesLastReport(for: error)
    }

    static func preservesLastReport(for error: any Error) -> Bool {
        guard let error = error as? ClaudeUsageClientError else { return false }
        switch error {
        case .executableNotFound, .helperNotFound:
            return false
        case .launchFailed, .timedOut, .usageUnavailable:
            return true
        }
    }
}
