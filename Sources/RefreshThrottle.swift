import Foundation

/// Throttles popover-open refreshes to a minimum interval between fetches.
struct RefreshThrottle: Equatable, Sendable {
    let maximumAge: TimeInterval

    init(maximumAge: TimeInterval) {
        precondition(maximumAge > 0)
        self.maximumAge = maximumAge
    }

    func shouldRefresh(lastSuccessfulRefreshAt: Date?, now: Date = .now) -> Bool {
        guard let lastSuccessfulRefreshAt else { return true }
        let age = now.timeIntervalSince(lastSuccessfulRefreshAt)
        return age < 0 || age >= maximumAge
    }
}
