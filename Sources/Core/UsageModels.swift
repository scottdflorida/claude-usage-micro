import Foundation

/// The independent usage windows reported by Claude Code's `/usage` screen.
enum UsageLimit: Hashable, Sendable {
    case session
    case allModels
    case fable
}

/// Usage and reset information for one rolling limit window.
struct UsageSnapshot: Equatable, Sendable {
    let usedPercent: Int
    let windowDuration: TimeInterval
    let resetsAt: Date

    init?(usedPercent: Int, windowDuration: TimeInterval, resetsAt: Date) {
        guard (0...100).contains(usedPercent), windowDuration > 0 else { return nil }
        self.usedPercent = usedPercent
        self.windowDuration = windowDuration
        self.resetsAt = resetsAt
    }

    var usageRemainingPercent: Int {
        100 - usedPercent
    }

    func timeRemainingFraction(at date: Date = .now) -> Double {
        min(1, max(0, resetsAt.timeIntervalSince(date) / windowDuration))
    }

    func timeRemainingPercent(at date: Date = .now) -> Int {
        Int((timeRemainingFraction(at: date) * 100).rounded())
    }
}

/// A complete, internally consistent reading of Claude's three usage limits.
struct UsageReport: Equatable, Sendable {
    let session: UsageSnapshot
    let allModels: UsageSnapshot
    let fable: UsageSnapshot

    subscript(limit: UsageLimit) -> UsageSnapshot {
        switch limit {
        case .session:
            session
        case .allModels:
            allModels
        case .fable:
            fable
        }
    }
}
