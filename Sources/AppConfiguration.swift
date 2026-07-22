import AppKit

enum AppConfiguration {
    struct Row {
        let limit: UsageLimit
        let timeLabel: String
        let usageLabel: String
        let accessibilityLabel: String
    }

    static let name = "Claude Usage Micro"
    static let title = "CLAUDE USAGE"
    static let initialToolTip = "Claude usage"
    static let refreshInterval: TimeInterval = RefreshConfiguration.minutes * 60
    static let clockRefreshInterval: TimeInterval = 60
    static let contentSize = NSSize(width: 320, height: 312)
    static let rows = [
        Row(
            limit: .session,
            timeLabel: "Session time remaining",
            usageLabel: "Session usage remaining",
            accessibilityLabel: "Current-session limit"
        ),
        Row(
            limit: .allModels,
            timeLabel: "Week remaining",
            usageLabel: "All-model usage remaining",
            accessibilityLabel: "Weekly all-model limit"
        ),
        Row(
            limit: .fable,
            timeLabel: "Week remaining",
            usageLabel: "Fable usage remaining",
            accessibilityLabel: "Weekly Fable limit"
        ),
    ]
}
