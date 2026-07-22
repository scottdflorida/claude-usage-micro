import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let client: ClaudeUsageClient
    private let preferencesStore: MenuBarPreferencesStore
    private let refreshThrottle: RefreshThrottle
    private let viewController = UsageViewController()
    private let popover = NSPopover()

    private var menuBarPreferences: MenuBarPreferences
    private var menuBarDisplayState = MenuBarDisplayState.loading
    private var statusItem: NSStatusItem?
    private var report: UsageReport?
    private var staleDiagnostic: String?
    private var refreshTask: Task<Void, Never>?
    private var usageTimer: Timer?
    private var clockTimer: Timer?
    private var localClickMonitor: Any?
    private var lastSuccessfulRefreshAt: Date?

    override init() {
        client = ClaudeUsageClient()
        let preferencesStore = MenuBarPreferencesStore()
        self.preferencesStore = preferencesStore
        refreshThrottle = RefreshThrottle(maximumAge: AppConfiguration.refreshInterval)
        menuBarPreferences = preferencesStore.load()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = AppConfiguration.contentSize
        popover.contentViewController = viewController

        viewController.onRefresh = { [weak self] in
            self?.refresh()
        }
        viewController.setMenuBarPreferences(menuBarPreferences)
        viewController.onMenuBarPreferencesChange = { [weak self] preferences in
            self?.applyMenuBarPreferences(preferences)
        }

        let statusItem = NSStatusBar.system.statusItem(
            withLength: MenuBarGaugeRenderer.statusItemLength
        )
        self.statusItem = statusItem
        // Deliberately no autosaveName: macOS would restore an externally hidden status item
        // as hidden on relaunch.
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = AppConfiguration.initialToolTip
            button.setAccessibilityLabel("Claude usage")
            button.setAccessibilityValue("Usage unavailable")
            button.setAccessibilityHelp("Opens current Claude session and weekly usage details.")
            renderStatusItem()
        }

        refresh()
        usageTimer = scheduledTimer(
            interval: AppConfiguration.refreshInterval,
            tolerance: AppConfiguration.refreshInterval / 10
        ) { [weak self] in
            self?.refresh()
        }
        clockTimer = scheduledTimer(
            interval: AppConfiguration.clockRefreshInterval,
            tolerance: 0.5
        ) { [weak self] in
            self?.updateClock()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
        usageTimer?.invalidate()
        clockTimer?.invalidate()
        stopClickOutsideMonitor()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if refreshThrottle.shouldRefresh(lastSuccessfulRefreshAt: lastSuccessfulRefreshAt) {
                refresh()
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startClickOutsideMonitor()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopClickOutsideMonitor()
    }

    private func refresh() {
        guard refreshTask == nil else { return }
        viewController.showLoading()
        if report == nil {
            menuBarDisplayState = .loading
            renderStatusItem()
            statusItem?.button?.toolTip = "Checking Claude usage"
            statusItem?.button?.setAccessibilityValue("Checking usage")
        }

        refreshTask = Task { [weak self, client] in
            defer { self?.refreshTask = nil }
            do {
                let report = try await client.fetchUsage()
                guard !Task.isCancelled, let self else { return }
                self.report = report
                self.staleDiagnostic = nil
                let now = Date.now
                self.lastSuccessfulRefreshAt = now
                self.viewController.show(report: report, at: now)
                self.updateStatusItem(report: report, at: now)
            } catch is CancellationError {
                // Application shutdown intentionally cancels an in-flight refresh.
            } catch {
                guard let self else { return }
                let diagnostic = error.localizedDescription
                if let report = self.report,
                    RefreshFailurePolicy.preservesLastReport(for: error, report: report)
                {
                    self.staleDiagnostic = diagnostic
                    self.viewController.show(report: report, status: .stale(diagnostic))
                    self.updateStatusItem(report: report, diagnostic: diagnostic)
                } else {
                    self.showUnavailable(diagnostic: diagnostic)
                }
            }
        }
    }

    private func updateClock(at date: Date = .now) {
        if let report, let staleDiagnostic, !report.hasUnexpiredUsage(at: date) {
            showUnavailable(diagnostic: staleDiagnostic)
            return
        }

        viewController.updateClock(at: date)
        if let report {
            updateStatusItem(report: report, at: date, diagnostic: staleDiagnostic)
        }
    }

    private func updateStatusItem(
        report: UsageReport,
        at date: Date = .now,
        diagnostic: String? = nil
    ) {
        menuBarDisplayState = .live(
            report: report,
            selection: menuBarPreferences.selectedGauge,
            at: date,
            freshness: diagnostic == nil ? .current : .stale
        )
        renderStatusItem()

        let orderedSelections =
            [menuBarPreferences.selectedGauge]
            + MenuBarGaugeSelection.allCases.filter {
                $0 != menuBarPreferences.selectedGauge
            }
        var toolTipLines: [String] = []
        if let diagnostic {
            toolTipLines.append("Last update shown · \(diagnostic)")
        }
        if report[menuBarPreferences.selectedGauge.usageLimit] == nil {
            toolTipLines.append(
                "\(menuBarPreferences.selectedGauge.title) · Not reported by Claude"
            )
        }
        toolTipLines.append(
            contentsOf: orderedSelections.compactMap { selection in
                guard let snapshot = report[selection.usageLimit] else { return nil }
                let timeName = selection == .session ? "Time left" : "Week left"
                return "\(selection.title) · Usage left \(snapshot.usageRemainingPercent)% · "
                    + "\(timeName) \(snapshot.timeRemainingPercent(at: date))%"
            }
        )
        statusItem?.button?.toolTip = toolTipLines.joined(separator: "\n")

        let accessibilityPrefix = diagnostic.map { "Last update shown. \($0). " } ?? ""
        if let selectedSnapshot = report[menuBarPreferences.selectedGauge.usageLimit] {
            statusItem?.button?.setAccessibilityValue(
                accessibilityPrefix
                    + "\(menuBarPreferences.selectedGauge.title) usage remaining "
                    + "\(selectedSnapshot.usageRemainingPercent) percent, time remaining "
                    + "\(selectedSnapshot.timeRemainingPercent(at: date)) percent"
            )
        } else {
            let availableCount = report.availableLimits.count
            statusItem?.button?.setAccessibilityValue(
                accessibilityPrefix
                    + "\(menuBarPreferences.selectedGauge.title) usage unavailable; "
                    + "\(availableCount) other usage limits available"
            )
        }
    }

    private func showUnavailable(diagnostic: String) {
        report = nil
        staleDiagnostic = nil
        lastSuccessfulRefreshAt = nil
        viewController.show(errorMessage: diagnostic)
        menuBarDisplayState = .unavailable
        renderStatusItem()
        statusItem?.button?.toolTip = diagnostic
        statusItem?.button?.setAccessibilityValue("Usage unavailable")
    }

    private func applyMenuBarPreferences(_ preferences: MenuBarPreferences) {
        menuBarPreferences = preferences
        preferencesStore.save(preferences)
        viewController.setMenuBarPreferences(preferences)

        if let report {
            updateStatusItem(report: report, diagnostic: staleDiagnostic)
        }
    }

    private func renderStatusItem() {
        guard let button = statusItem?.button else { return }

        button.image = MenuBarGaugeRenderer.image(for: menuBarDisplayState)
        statusItem?.isVisible = true
    }

    private func startClickOutsideMonitor() {
        guard localClickMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            let popoverWindow = self.popover.contentViewController?.view.window
            let statusWindow = self.statusItem?.button?.window
            if event.window !== popoverWindow && event.window !== statusWindow {
                self.popover.performClose(nil)
            }
            return event
        }
    }

    private func stopClickOutsideMonitor() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }

    private func scheduledTimer(
        interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated(action)
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
