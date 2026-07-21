import AppKit
import Foundation

private enum ProviderConfig {
    struct RowLabels {
        let time: String
        let usage: String
    }

    static let appName = "Claude Usage Micro"
    static let title = "CLAUDE USAGE"
    static let menuPrefix = "Cd"
    static let toolTip = "Claude weekly usage"
    static let refreshInterval = RefreshConfiguration.minutes * 60
    static let contentSize = NSSize(width: 320, height: 312)
    static let statusLimitIndex = 1
    static let rows = [
        RowLabels(time: "Session Time Remaining", usage: "Session usage remaining"),
        RowLabels(time: "Week remaining", usage: "All-model usage remaining"),
        RowLabels(time: "Week remaining", usage: "Fable usage remaining")
    ]
}

private struct UsageSnapshot: Sendable {
    let usedPercent: Int
    let windowDurationMinutes: Int
    let resetsAt: Date

    var usageRemainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    func weekRemaining(at date: Date = Date()) -> Double {
        let duration = Double(windowDurationMinutes) * 60
        guard duration > 0 else { return 0 }
        return max(0, min(1, resetsAt.timeIntervalSince(date) / duration))
    }
}

private struct UsageReport: Sendable {
    let limits: [UsageSnapshot]
}


private enum ClaudeClientError: LocalizedError {
    case executableNotFound
    case helperNotFound
    case launchFailed(String)
    case usageUnavailable

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Claude Code is not installed"
        case .helperNotFound:
            return "Claude usage helper is missing"
        case .launchFailed(let message):
            return "Could not read Claude usage: \(message)"
        case .usageUnavailable:
            return "Claude returned an unfamiliar usage screen"
        }
    }
}

private final class ClaudeClient: @unchecked Sendable {
    func fetch(completion: @escaping @Sendable (Result<UsageReport, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.fetchSynchronously())
        }
    }

    func fetchSynchronously() -> Result<UsageReport, Error> {
        guard let executable = Self.findClaudeExecutable() else {
            return .failure(ClaudeClientError.executableNotFound)
        }
        guard let helper = Bundle.main.url(forResource: "claude-usage", withExtension: "exp") else {
            return .failure(ClaudeClientError.helperNotFound)
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        process.arguments = [helper.path, executable.path]
        let buildDirectory = Bundle.main.bundleURL.deletingLastPathComponent()
        process.currentDirectoryURL = buildDirectory.lastPathComponent == "build"
            ? buildDirectory.deletingLastPathComponent()
            : buildDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        if environment["LANG"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        process.environment = environment
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            return .failure(ClaudeClientError.launchFailed(error.localizedDescription))
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let transcript = String(decoding: data, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            let diagnostic = Self.flattenTerminalOutput(transcript)
                .split(separator: "\n")
                .suffix(3)
                .joined(separator: " · ")
            let detail = diagnostic.isEmpty ? "exit (process.terminationStatus)" : diagnostic
            return .failure(ClaudeClientError.launchFailed(detail))
        }

        guard let report = Self.parseUsage(transcript) else {
            return .failure(ClaudeClientError.usageUnavailable)
        }
        return .success(report)
    }

    private static func parseUsage(_ transcript: String, now: Date = Date()) -> UsageReport? {
        let text = flattenTerminalOutput(transcript)
        guard
            let sessionSection = section(
                named: "Current session",
                before: "Current week (all models)",
                in: text,
                useLast: false
            ),
            let weeklySection = section(
                named: "Current week (all models)",
                before: "Current week (Fable)",
                in: text,
                useLast: true
            ),
            let fableSection = section(
                named: "Current week (Fable)",
                before: "What's contributing",
                in: text,
                useLast: true
            ),
            let sessionUsed = usedPercent(in: sessionSection),
            let weeklyUsed = usedPercent(in: weeklySection),
            let fableUsed = usedPercent(in: fableSection),
            let sessionReset = sessionResetDate(in: sessionSection, now: now),
            let weeklyReset = weeklyResetDate(in: weeklySection, now: now)
        else { return nil }

        return UsageReport(limits: [
            UsageSnapshot(usedPercent: sessionUsed, windowDurationMinutes: 300, resetsAt: sessionReset),
            UsageSnapshot(usedPercent: weeklyUsed, windowDurationMinutes: 10_080, resetsAt: weeklyReset),
            UsageSnapshot(usedPercent: fableUsed, windowDurationMinutes: 10_080, resetsAt: weeklyReset)
        ])
    }

    private static func flattenTerminalOutput(_ transcript: String) -> String {
        let pattern = #"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\)|[()][A-Z0-9]|.)"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        let withoutANSI = regex?.stringByReplacingMatches(
            in: transcript,
            range: range,
            withTemplate: ""
        ) ?? transcript

        let normalized = withoutANSI.replacingOccurrences(of: "\r", with: "\n")
        return String(normalized.unicodeScalars.filter { scalar in
            scalar.value == 0x0A || scalar.value == 0x09 || scalar.value >= 0x20
        })
    }

    private static func section(
        named heading: String,
        before nextHeading: String,
        in text: String,
        useLast: Bool
    ) -> String? {
        let options: String.CompareOptions = useLast ? .backwards : []
        guard let start = text.range(of: heading, options: options) else { return nil }
        let tail = text[start.upperBound...]
        guard let end = tail.range(of: nextHeading) else { return String(tail) }
        return String(tail[..<end.lowerBound])
    }

    private static func usedPercent(in section: String) -> Int? {
        guard let value = captures(#"(\d{1,3})%\s*used"#, in: section).first else { return nil }
        return Int(value)
    }

    private static func sessionResetDate(in section: String, now: Date) -> Date? {
        let values = captures(
            #"Resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)"#,
            in: section
        )
        guard values.count == 4 else { return nil }

        let hour = normalizedHour(Int(values[0]) ?? 0, meridiem: values[2])
        let minute = Int(values[1]) ?? 0
        let timeZone = TimeZone(identifier: values[3]) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard var reset = calendar.date(from: components) else { return nil }
        if reset <= now { reset = calendar.date(byAdding: .day, value: 1, to: reset) ?? reset }
        return reset
    }

    private static func weeklyResetDate(in section: String, now: Date) -> Date? {
        let values = captures(
            #"Resets\s+([A-Z][a-z]{2})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)"#,
            in: section
        )
        guard values.count == 6 else { return nil }

        let months = [
            "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
            "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12
        ]
        guard let month = months[values[0]] else { return nil }

        let timeZone = TimeZone(identifier: values[5]) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.timeZone = timeZone
        components.year = calendar.component(.year, from: now)
        components.month = month
        components.day = Int(values[1])
        components.hour = normalizedHour(Int(values[2]) ?? 0, meridiem: values[4])
        components.minute = Int(values[3]) ?? 0
        components.second = 0
        guard var reset = calendar.date(from: components) else { return nil }
        if reset <= now { reset = calendar.date(byAdding: .year, value: 1, to: reset) ?? reset }
        return reset
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return [] }
        return (1..<match.numberOfRanges).map { index in
            let matchRange = match.range(at: index)
            guard matchRange.location != NSNotFound, let range = Range(matchRange, in: text) else {
                return ""
            }
            return String(text[range])
        }
    }

    private static func normalizedHour(_ hour: Int, meridiem: String) -> Int {
        let base = hour % 12
        return meridiem.lowercased() == "pm" ? base + 12 : base
    }

    private static func findClaudeExecutable() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]

        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

private final class ComparisonBarView: NSView {
    private let weekName = NSTextField(labelWithString: "Week remaining")
    private let weekValue = NSTextField(labelWithString: "—")
    private let usageName = NSTextField(labelWithString: "Usage remaining")
    private let usageValue = NSTextField(labelWithString: "—")

    private var weekFraction = 0.0
    private var usageFraction = 0.0
    private var usageColor = NSColor.systemGray
    private var trackRect: NSRect = .zero

    init(timeLabel: String, usageLabel: String) {
        super.init(frame: .zero)
        weekName.stringValue = timeLabel
        usageName.stringValue = usageLabel
        translatesAutoresizingMaskIntoConstraints = false

        weekName.font = .systemFont(ofSize: 12, weight: .medium)
        usageName.font = .systemFont(ofSize: 12, weight: .bold)
        for label in [weekName, usageName] {
            label.textColor = .secondaryLabelColor
            addSubview(label)
        }

        for label in [weekValue, usageValue] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            label.alignment = .center
            addSubview(label)
        }

        setAccessibilityElement(true)
        setAccessibilityLabel("Weekly usage comparison")
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 62)
    }

    override func layout() {
        super.layout()

        let rowHeight: CGFloat = 17
        let trackHeight: CGFloat = 10
        trackRect = NSRect(
            x: bounds.minX,
            y: bounds.midY - trackHeight / 2,
            width: bounds.width,
            height: trackHeight
        )

        layoutRow(
            name: usageName,
            value: usageValue,
            fraction: usageFraction,
            y: bounds.maxY - rowHeight,
            rowHeight: rowHeight
        )
        layoutRow(
            name: weekName,
            value: weekValue,
            fraction: weekFraction,
            y: bounds.minY,
            rowHeight: rowHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard trackRect.width > 0 else { return }

        let radius = trackRect.height / 2
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let trackColor = isDark
            ? NSColor.white.withAlphaComponent(0.24)
            : NSColor.black.withAlphaComponent(0.14)
        trackColor.setFill()
        trackPath.fill()

        NSGraphicsContext.saveGraphicsState()
        trackPath.addClip()
        let fillWidth = trackRect.width * max(0, min(1, usageFraction))
        usageColor.setFill()
        NSBezierPath(rect: NSRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: fillWidth,
            height: trackRect.height
        )).fill()
        NSGraphicsContext.restoreGraphicsState()

        let markerWidth: CGFloat = 3
        let rawMarkerX = trackRect.minX + trackRect.width * max(0, min(1, weekFraction))
        let markerX = max(trackRect.minX, min(trackRect.maxX - markerWidth, rawMarkerX - markerWidth / 2))
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: NSRect(
            x: markerX,
            y: trackRect.minY - 2,
            width: markerWidth,
            height: trackRect.height + 4
        ), xRadius: 1.5, yRadius: 1.5).fill()
    }

    func update(
        weekPercent: Int,
        weekFraction: Double,
        usagePercent: Int,
        usageFraction: Double,
        color: NSColor
    ) {
        self.weekFraction = max(0, min(1, weekFraction))
        self.usageFraction = max(0, min(1, usageFraction))
        usageColor = color
        weekValue.stringValue = "\(weekPercent)%"
        usageValue.stringValue = "\(usagePercent)%"
        setAccessibilityValue("Week remaining \(weekPercent) percent, usage remaining \(usagePercent) percent")
        needsLayout = true
        needsDisplay = true
    }

    private func layoutRow(
        name: NSTextField,
        value: NSTextField,
        fraction: Double,
        y: CGFloat,
        rowHeight: CGFloat
    ) {
        name.sizeToFit()
        value.sizeToFit()
        let valueWidth = value.frame.width
        let markerCenter = bounds.minX + bounds.width * max(0, min(1, fraction))
        let valueX = max(bounds.minX, min(bounds.maxX - valueWidth, markerCenter - valueWidth / 2))

        value.frame = NSRect(x: valueX, y: y, width: valueWidth, height: rowHeight)

        let nameWidth = name.frame.width
        let gap: CGFloat = 2.5
        let placeNameOnLeft = fraction > 0.5
        let nameX: CGFloat
        if placeNameOnLeft {
            name.alignment = .right
            nameX = max(bounds.minX, value.frame.minX - gap - nameWidth)
        } else {
            name.alignment = .left
            nameX = min(bounds.maxX - nameWidth, value.frame.maxX + gap)
        }
        name.frame = NSRect(x: nameX, y: y, width: nameWidth, height: rowHeight)
    }
}

private final class SectionDividerView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 9)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = isDark
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.12)
        color.setFill()
        NSBezierPath(rect: NSRect(
            x: bounds.minX,
            y: floor(bounds.midY),
            width: bounds.width,
            height: 1
        )).fill()
    }
}

private final class UsageViewController: NSViewController {
    private let comparisonBars = ProviderConfig.rows.map {
        ComparisonBarView(timeLabel: $0.time, usageLabel: $0.usage)
    }
    private let resetLabel = NSTextField(labelWithString: "Checking \(ProviderConfig.appName)…")
    private let statusLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private let sessionResetLabel = NSTextField(labelWithString: "Session Reset: —")
    private let sessionResetRow = NSView()
    private let weeklyResetLabel = NSTextField(labelWithString: "Weekly Reset: —")
    private let sectionDivider = SectionDividerView()
    private var report: UsageReport?

    var onRefresh: (() -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: ProviderConfig.contentSize))
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: ProviderConfig.title)
        title.font = .systemFont(ofSize: 12, weight: .bold)
        title.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .right

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)
        header.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 16),
            title.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        resetLabel.font = .systemFont(ofSize: 11)
        resetLabel.textColor = .secondaryLabelColor
        for label in [sessionResetLabel, weeklyResetLabel] {
            label.font = .systemFont(ofSize: 10.5, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .left
        }
        sessionResetRow.translatesAutoresizingMaskIntoConstraints = false
        sessionResetLabel.translatesAutoresizingMaskIntoConstraints = false
        sessionResetRow.addSubview(sessionResetLabel)
        NSLayoutConstraint.activate([
            sessionResetRow.heightAnchor.constraint(equalToConstant: 14),
            sessionResetLabel.leadingAnchor.constraint(equalTo: sessionResetRow.leadingAnchor),
            sessionResetLabel.centerYAnchor.constraint(equalTo: sessionResetRow.centerYAnchor),
            sessionResetLabel.trailingAnchor.constraint(lessThanOrEqualTo: sessionResetRow.trailingAnchor)
        ])

        refreshButton.bezelStyle = .inline
        refreshButton.controlSize = .small
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)

        quitButton.bezelStyle = .inline
        quitButton.controlSize = .small
        quitButton.target = self
        quitButton.action = #selector(quitPressed)

        let spacer = NSView()
        let footer = NSStackView(views: [weeklyResetLabel, spacer, refreshButton, quitButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.alignment = .centerY

        let stackViews: [NSView] = [
            header,
            comparisonBars[0],
            sessionResetRow,
            sectionDivider,
            comparisonBars[1],
            comparisonBars[2],
            footer
        ]
        let stack = NSStackView(views: stackViews)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 7
        stack.setCustomSpacing(3, after: comparisonBars[0])
        stack.setCustomSpacing(7, after: sessionResetRow)
        stack.setCustomSpacing(8, after: sectionDivider)
        stack.setCustomSpacing(12, after: comparisonBars[1])
        stack.setCustomSpacing(3, after: comparisonBars[2])
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let bottomInset: CGFloat = 3
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: ProviderConfig.contentSize.width),
            root.heightAnchor.constraint(equalToConstant: ProviderConfig.contentSize.height),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -bottomInset)
        ])

        view = root
    }

    func showLoading() {
        refreshButton.isEnabled = false
        statusLabel.stringValue = "Updating…"
    }

    func show(report: UsageReport) {
        self.report = report
        refreshButton.isEnabled = true
        statusLabel.stringValue = "Live"
        updateClock()
    }

    func show(error: Error) {
        report = nil
        refreshButton.isEnabled = true
        statusLabel.stringValue = "Unavailable"
        sessionResetLabel.stringValue = error.localizedDescription
        weeklyResetLabel.stringValue = ""
        for bar in comparisonBars {
            bar.update(
                weekPercent: 0,
                weekFraction: 0,
                usagePercent: 0,
                usageFraction: 0,
                color: .systemGray
            )
        }
    }

    func updateClock(at date: Date = Date()) {
        guard let report else { return }

        for (bar, snapshot) in zip(comparisonBars, report.limits) {
            let timeFraction = snapshot.weekRemaining(at: date)
            let timePercent = Int((timeFraction * 100).rounded())
            let usagePercent = snapshot.usageRemainingPercent
            let usageFraction = Double(usagePercent) / 100

            let usageColor: NSColor
            if usagePercent < 15 {
                usageColor = .systemRed
            } else if usagePercent >= timePercent {
                usageColor = .systemGreen
            } else {
                usageColor = .systemOrange
            }
            bar.update(
                weekPercent: timePercent,
                weekFraction: timeFraction,
                usagePercent: usagePercent,
                usageFraction: usageFraction,
                color: usageColor
            )
        }

        if report.limits.count >= 2 {
            let sessionFormatter = DateFormatter()
            sessionFormatter.dateFormat = "h:mm a"
            let weekFormatter = DateFormatter()
            weekFormatter.dateFormat = "EEE h:mm a"
            sessionResetLabel.stringValue = "Session Reset: \(sessionFormatter.string(from: report.limits[0].resetsAt))"
            weeklyResetLabel.stringValue = "Weekly Reset: \(weekFormatter.string(from: report.limits[1].resetsAt))"
        }
    }

    @objc private func refreshPressed() {
        onRefresh?()
    }

    @objc private func quitPressed() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit \(ProviderConfig.appName)?"
        alert.informativeText = "The menu-bar indicator will disappear until you open \(ProviderConfig.appName) again."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSApp.terminate(nil)
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, @unchecked Sendable {
    private let client = ClaudeClient()
    private let viewController = UsageViewController()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var report: UsageReport?
    private var usageTimer: Timer?
    private var clockTimer: Timer?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = ProviderConfig.contentSize
        popover.contentViewController = viewController

        viewController.onRefresh = { [weak self] in self?.refresh() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "\(ProviderConfig.menuPrefix) —"
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = ProviderConfig.toolTip
        }

        refresh()
        usageTimer = Timer.scheduledTimer(withTimeInterval: ProviderConfig.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startClickOutsideMonitors()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopClickOutsideMonitors()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopClickOutsideMonitors()
    }

    private func refresh() {
        viewController.showLoading()
        client.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let report):
                    self.report = report
                    self.viewController.show(report: report)
                    self.updateStatusItem(report: report)
                case .failure(let error):
                    self.report = nil
                    self.viewController.show(error: error)
                    self.statusItem.button?.title = "\(ProviderConfig.menuPrefix) !"
                    self.statusItem.button?.toolTip = error.localizedDescription
                }
            }
        }
    }

    private func tick() {
        viewController.updateClock()
        if let report { updateStatusItem(report: report) }
    }

    private func updateStatusItem(report: UsageReport) {
        guard report.limits.indices.contains(ProviderConfig.statusLimitIndex) else { return }
        let snapshot = report.limits[ProviderConfig.statusLimitIndex]
        let usage = snapshot.usageRemainingPercent
        statusItem.button?.title = "\(ProviderConfig.menuPrefix) \(usage)%"
        guard report.limits.count >= 3 else { return }
        let session = report.limits[0]
        let allModels = report.limits[1]
        let fable = report.limits[2]
        let sessionTime = Int((session.weekRemaining() * 100).rounded())
        let weeklyTime = Int((allModels.weekRemaining() * 100).rounded())
        statusItem.button?.toolTip = [
            "Session · Usage left \(session.usageRemainingPercent)% · Time left \(sessionTime)%",
            "All models · Usage left \(allModels.usageRemainingPercent)% · Week left \(weeklyTime)%",
            "Fable · Usage left \(fable.usageRemainingPercent)% · Week left \(weeklyTime)%"
        ].joined(separator: "\n")
    }

    private func startClickOutsideMonitors() {
        guard localClickMonitor == nil, globalClickMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            let popoverWindow = self.popover.contentViewController?.view.window
            let statusWindow = self.statusItem.button?.window
            if event.window !== popoverWindow && event.window !== statusWindow {
                self.popover.performClose(nil)
            }
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            DispatchQueue.main.async {
                self?.popover.performClose(nil)
            }
        }
    }

    private func stopClickOutsideMonitors() {
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }
}

@main
private enum UsageMicroMain {
    static func main() {
        if CommandLine.arguments.contains("--snapshot") {
            let result: Result<UsageReport, Error>
            result = ClaudeClient().fetchSynchronously()
            switch result {
            case .success(let report):
                for (index, snapshot) in report.limits.enumerated() {
                    let time = Int((snapshot.weekRemaining() * 100).rounded())
                    print("limit_\(index)_time_remaining=\(time)")
                    print("limit_\(index)_usage_remaining=\(snapshot.usageRemainingPercent)")
                    print("limit_\(index)_resets_at=\(Int(snapshot.resetsAt.timeIntervalSince1970))")
                }
                exit(EXIT_SUCCESS)
            case .failure(let error):
                fputs("\(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
