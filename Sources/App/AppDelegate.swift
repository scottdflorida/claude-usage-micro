import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client: ClaudeUsageClient
    private let viewController = UsageViewController()
    private let popover = NSPopover()

    private var statusItem: NSStatusItem?
    private var report: UsageReport?
    private var refreshTask: Task<Void, Never>?
    private var usageTimer: Timer?
    private var clockTimer: Timer?

    override init() {
        client = ClaudeUsageClient()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        popover.behavior = .transient
        popover.contentSize = AppConfiguration.contentSize
        popover.contentViewController = viewController

        viewController.onRefresh = { [weak self] in
            self?.refresh()
        }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem
        if let button = statusItem.button {
            button.title = "\(AppConfiguration.menuPrefix) —"
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = AppConfiguration.initialToolTip
            button.setAccessibilityLabel("Claude usage")
            button.setAccessibilityValue("Usage unavailable")
            button.setAccessibilityHelp("Opens current Claude session and weekly usage details.")
        }

        refresh()
        usageTimer = scheduledTimer(
            interval: AppConfiguration.refreshInterval,
            selector: #selector(refreshTimerFired)
        )
        clockTimer = scheduledTimer(interval: 60, selector: #selector(clockTimerFired))
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
        usageTimer?.invalidate()
        clockTimer?.invalidate()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func refreshTimerFired() {
        refresh()
    }

    @objc private func clockTimerFired() {
        updateClock()
    }

    private func refresh() {
        guard refreshTask == nil else { return }
        viewController.showLoading()

        refreshTask = Task { [weak self, client] in
            defer { self?.refreshTask = nil }
            do {
                let report = try await client.fetchUsage()
                guard !Task.isCancelled, let self else { return }
                self.report = report
                let now = Date.now
                self.viewController.show(report: report, at: now)
                self.updateStatusItem(report: report, at: now)
            } catch is CancellationError {
                // Application shutdown intentionally cancels an in-flight refresh.
            } catch {
                guard let self else { return }
                self.report = nil
                self.viewController.show(error: error)
                self.statusItem?.button?.title = "\(AppConfiguration.menuPrefix) !"
                self.statusItem?.button?.toolTip = error.localizedDescription
                self.statusItem?.button?.setAccessibilityValue("Usage unavailable")
            }
        }
    }

    private func updateClock(at date: Date = .now) {
        viewController.updateClock(at: date)
        if let report {
            updateStatusItem(report: report, at: date)
        }
    }

    private func updateStatusItem(report: UsageReport, at date: Date) {
        let statusSnapshot = report[AppConfiguration.statusLimit]
        statusItem?.button?.title = "\(AppConfiguration.menuPrefix) \(statusSnapshot.usageRemainingPercent)%"
        statusItem?.button?.toolTip = [
            "Session · Usage left \(report.session.usageRemainingPercent)% · Time left \(report.session.timeRemainingPercent(at: date))%",
            "All models · Usage left \(report.allModels.usageRemainingPercent)% · Week left \(report.allModels.timeRemainingPercent(at: date))%",
            "Fable · Usage left \(report.fable.usageRemainingPercent)% · Week left \(report.fable.timeRemainingPercent(at: date))%",
        ].joined(separator: "\n")
        statusItem?.button?.setAccessibilityValue(
            "Session usage remaining \(report.session.usageRemainingPercent) percent, time remaining \(report.session.timeRemainingPercent(at: date)) percent; "
                + "all-model usage remaining \(report.allModels.usageRemainingPercent) percent, week remaining \(report.allModels.timeRemainingPercent(at: date)) percent; "
                + "Fable usage remaining \(report.fable.usageRemainingPercent) percent, week remaining \(report.fable.timeRemainingPercent(at: date)) percent"
        )
    }

    private func scheduledTimer(interval: TimeInterval, selector: Selector) -> Timer {
        let timer = Timer(timeInterval: interval, target: self, selector: selector, userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
