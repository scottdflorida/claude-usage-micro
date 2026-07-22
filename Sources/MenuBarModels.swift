import Foundation

enum MenuBarGaugeSelection: String, CaseIterable, Equatable, Sendable {
    case session
    case allModels
    case fable

    var title: String {
        switch self {
        case .session:
            "Current Session"
        case .allModels:
            "Weekly — All Models"
        case .fable:
            "Weekly — Fable"
        }
    }

    var usageLimit: UsageLimit {
        switch self {
        case .session:
            .session
        case .allModels:
            .allModels
        case .fable:
            .fable
        }
    }
}

struct MenuBarPreferences: Equatable, Sendable {
    var selectedGauge: MenuBarGaugeSelection

    static let standard = MenuBarPreferences(
        selectedGauge: .allModels
    )
}

struct MenuBarPreferencesStore {
    static let suiteName = "com.scottflorida.claudeusagemicro"

    private enum Key {
        static let selectedGauge = "menuBar.selectedGauge"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.suiteName) ?? .standard
    }

    func load() -> MenuBarPreferences {
        let selectedGauge =
            defaults.string(forKey: Key.selectedGauge)
            .flatMap(MenuBarGaugeSelection.init(rawValue:))
            ?? MenuBarPreferences.standard.selectedGauge
        return MenuBarPreferences(
            selectedGauge: selectedGauge
        )
    }

    func save(_ preferences: MenuBarPreferences) {
        defaults.set(preferences.selectedGauge.rawValue, forKey: Key.selectedGauge)
    }
}

struct MenuBarItemLayout: Equatable, Sendable {
    let statusItemWidth: Double
    let imageWidth: Double
    let brandSlotWidth: Double
    let gaugeOriginX: Double
    let gaugeWidth: Double

    static let standard = MenuBarItemLayout(
        statusItemWidth: 48,
        imageWidth: 44,
        brandSlotWidth: 44,
        gaugeOriginX: 0,
        gaugeWidth: 44
    )
}

enum MenuBarGaugePace: Equatable, Sendable {
    case critical
    case onPace
    case behind
}

struct MenuBarGaugeReading: Equatable, Sendable {
    let usageRemainingFraction: Double
    let timeRemainingFraction: Double
    let usageRemainingPercent: Int
    let pace: MenuBarGaugePace
}

enum MenuBarGaugeState: Equatable, Sendable {
    case loading
    case value(MenuBarGaugeReading)
    case unavailable

    var statusSymbol: String? {
        switch self {
        case .loading:
            "…"
        case .value:
            nil
        case .unavailable:
            "!"
        }
    }
}

enum MenuBarFreshness: Equatable, Sendable {
    case current
    case stale
}

struct MenuBarDisplayState: Equatable, Sendable {
    let brandName: String
    let gauge: MenuBarGaugeState
    let freshness: MenuBarFreshness

    static let loading = MenuBarDisplayState(
        brandName: "Claude",
        gauge: .loading,
        freshness: .current
    )

    static let unavailable = MenuBarDisplayState(
        brandName: "Claude",
        gauge: .unavailable,
        freshness: .current
    )

    static func live(
        report: UsageReport,
        selection: MenuBarGaugeSelection,
        at date: Date = .now,
        freshness: MenuBarFreshness = .current
    ) -> MenuBarDisplayState {
        guard let snapshot = report[selection.usageLimit] else {
            return unavailable
        }

        let reading = snapshot.reading(at: date)
        return MenuBarDisplayState(
            brandName: "Claude",
            gauge: .value(
                MenuBarGaugeReading(
                    usageRemainingFraction: reading.usageRemainingFraction,
                    timeRemainingFraction: reading.timeRemainingFraction,
                    usageRemainingPercent: reading.usageRemainingPercent,
                    pace: MenuBarGaugePace(reading.pace)
                )
            ),
            freshness: freshness
        )
    }
}

extension MenuBarGaugePace {
    fileprivate init(_ pace: UsagePace) {
        switch pace {
        case .critical:
            self = .critical
        case .onPace:
            self = .onPace
        case .behind:
            self = .behind
        }
    }
}
