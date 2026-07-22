import Foundation

/// The independent usage windows reported by Claude Code's `/usage` screen.
enum UsageLimit: CaseIterable, Hashable, Sendable {
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
        (resetsAt.timeIntervalSince(date) / windowDuration).clamped(to: 0...1)
    }

    func timeRemainingPercent(at date: Date = .now) -> Int {
        Int((timeRemainingFraction(at: date) * 100).rounded())
    }

    func reading(at date: Date = .now) -> UsageReading {
        let timeFraction = timeRemainingFraction(at: date)
        let timePercent = Int((timeFraction * 100).rounded())
        let usagePercent = usageRemainingPercent

        let pace: UsagePace
        if usagePercent < 15 {
            pace = .critical
        } else if Double(usagePercent) / 100 >= timeFraction {
            pace = .onPace
        } else {
            pace = .behind
        }

        return UsageReading(
            timeRemainingFraction: timeFraction,
            timeRemainingPercent: timePercent,
            usageRemainingPercent: usagePercent,
            pace: pace
        )
    }
}

struct UsageReading: Equatable, Sendable {
    let timeRemainingFraction: Double
    let timeRemainingPercent: Int
    let usageRemainingPercent: Int
    let pace: UsagePace

    var usageRemainingFraction: Double {
        Double(usageRemainingPercent) / 100
    }
}

enum UsagePace: Equatable, Sendable {
    case critical
    case onPace
    case behind
}

/// The independently validated usage limits available in one Claude `/usage` reading.
struct UsageReport: Equatable, Sendable {
    private let snapshots: [UsageLimit: UsageSnapshot]

    init?(
        session: UsageSnapshot? = nil,
        allModels: UsageSnapshot? = nil,
        fable: UsageSnapshot? = nil
    ) {
        let snapshots = [
            UsageLimit.session: session,
            UsageLimit.allModels: allModels,
            UsageLimit.fable: fable,
        ].compactMapValues { $0 }
        guard !snapshots.isEmpty else { return nil }
        self.snapshots = snapshots
    }

    var session: UsageSnapshot? { self[.session] }
    var allModels: UsageSnapshot? { self[.allModels] }
    var fable: UsageSnapshot? { self[.fable] }

    var availableLimits: [UsageLimit] {
        UsageLimit.allCases.filter { snapshots[$0] != nil }
    }

    var isComplete: Bool {
        snapshots.count == UsageLimit.allCases.count
    }

    func hasUnexpiredUsage(at date: Date = .now) -> Bool {
        snapshots.values.contains { $0.resetsAt > date }
    }

    subscript(limit: UsageLimit) -> UsageSnapshot? {
        snapshots[limit]
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
