import AppKit
import Foundation

func menuBarTests() -> [TestCase] {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func snapshot(usedPercent: Int, windowDuration: TimeInterval) -> UsageSnapshot {
        guard
            let snapshot = UsageSnapshot(
                usedPercent: usedPercent,
                windowDuration: windowDuration,
                resetsAt: now.addingTimeInterval(windowDuration / 2)
            )
        else {
            preconditionFailure("Invalid menu-bar snapshot fixture")
        }
        return snapshot
    }

    func report(includeFable: Bool = true) -> UsageReport {
        guard
            let report = UsageReport(
                session: snapshot(usedPercent: 12, windowDuration: 5 * 60 * 60),
                allModels: snapshot(usedPercent: 34, windowDuration: 7 * 24 * 60 * 60),
                fable: includeFable ? snapshot(usedPercent: 56, windowDuration: 7 * 24 * 60 * 60) : nil
            )
        else {
            preconditionFailure("Invalid menu-bar report fixture")
        }
        return report
    }

    return [
        TestCase(name: "menu-bar preferences persist and reject unknown gauges") {
            try expectEqual(
                MenuBarPreferencesStore.suiteName,
                ProcessInfo.processInfo.environment["MENU_BAR_TEST_BUNDLE_ID"]
            )
            let suiteName = "ClaudeUsageMicroTests.menuBar.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw TestFailure(description: "Could not create isolated defaults")
            }
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let store = MenuBarPreferencesStore(defaults: defaults)
            try expectEqual(store.load(), .standard)

            let preferences = MenuBarPreferences(selectedGauge: .fable)
            store.save(preferences)
            try expectEqual(store.load(), preferences)

            defaults.set("future-limit", forKey: "menuBar.selectedGauge")
            try expectEqual(store.load().selectedGauge, .allModels)
        },
        TestCase(name: "menu-bar geometry permanently stacks the brand above the gauge") {
            let layout = MenuBarItemLayout.standard
            try expect(
                layout.statusItemWidth > layout.imageWidth,
                "status item must reserve button padding"
            )
            try expect(
                layout.brandSlotWidth == layout.imageWidth,
                "brand and gauge must share the same stacked width"
            )
            try expect(
                layout.gaugeOriginX + layout.gaugeWidth <= layout.imageWidth,
                "gauge must remain inside the image"
            )
        },
        TestCase(name: "menu-bar gauge follows the selected limit") {
            let display = MenuBarDisplayState.live(report: report(), selection: .fable, at: now)
            try expectEqual(display.brandName, "Claude")
            guard case .value(let reading) = display.gauge else {
                throw TestFailure(description: "expected a live Fable gauge")
            }
            try expectEqual(reading.usageRemainingPercent, 44)
            try expectEqual(MenuBarPreferences.standard.selectedGauge, .allModels)
            try expectEqual(MenuBarDisplayState.loading.brandName, "Claude")
            try expectEqual(MenuBarDisplayState.unavailable.brandName, "Claude")
            try expectEqual(MenuBarGaugeState.loading.statusSymbol, "…")
            try expectEqual(MenuBarGaugeState.unavailable.statusSymbol, "!")
        },
        TestCase(name: "a missing selected limit renders as unavailable") {
            let display = MenuBarDisplayState.live(
                report: report(includeFable: false),
                selection: .fable,
                at: now
            )
            try expectEqual(display, .unavailable)
        },
        TestCase(name: "stale menu-bar usage keeps its reading and gains a visible badge") {
            let current = MenuBarDisplayState.live(report: report(), selection: .allModels, at: now)
            let stale = MenuBarDisplayState.live(
                report: report(),
                selection: .allModels,
                at: now,
                freshness: .stale
            )
            try expectEqual(current.freshness, .current)
            try expectEqual(stale.freshness, .stale)
            guard case .value = stale.gauge else {
                throw TestFailure(description: "expected the stale gauge to keep its reading")
            }
            try expectEqual(MenuBarDisplayState.loading.freshness, .current)
            try expectEqual(MenuBarDisplayState.unavailable.freshness, .current)

            try await MainActor.run {
                let currentImage = MenuBarGaugeRenderer.image(for: current)
                let staleImage = MenuBarGaugeRenderer.image(for: stale)
                try expect(
                    currentImage.tiffRepresentation != staleImage.tiffRepresentation,
                    "expected stale rendering to differ visibly"
                )
            }
        },
    ]
}
