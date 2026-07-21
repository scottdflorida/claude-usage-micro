import AppKit

enum AppConfiguration {
    struct Row {
        let limit: UsageLimit
        let timeLabel: String
        let usageLabel: String
    }

    static let appName = "Claude Usage Micro"
    static let title = "CLAUDE USAGE"
    static let menuPrefix = "Cd"
    static let initialToolTip = "Claude weekly usage"
    static let refreshInterval: TimeInterval = RefreshConfiguration.minutes * 60
    static let contentSize = NSSize(width: 320, height: 312)
    static let statusLimit: UsageLimit = .allModels
    static let rows = [
        Row(
            limit: .session,
            timeLabel: "Session Time Remaining",
            usageLabel: "Session usage remaining"
        ),
        Row(
            limit: .allModels,
            timeLabel: "Week remaining",
            usageLabel: "All-model usage remaining"
        ),
        Row(
            limit: .fable,
            timeLabel: "Week remaining",
            usageLabel: "Fable usage remaining"
        ),
    ]
}

enum RefreshConfiguration {
    // Developer configuration: adjust this value to change the automatic refresh cadence.
    static let minutes: TimeInterval = 15
}
