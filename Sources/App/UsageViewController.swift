import AppKit

@MainActor
final class UsageViewController: NSViewController {
    private let comparisonBars: [UsageLimit: ComparisonBarView] = Dictionary(
        uniqueKeysWithValues: AppConfiguration.rows.map { row in
            (
                row.limit,
                ComparisonBarView(timeLabel: row.timeLabel, usageLabel: row.usageLabel)
            )
        }
    )
    private let statusLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private let sessionResetLabel = NSTextField(labelWithString: "Session Reset: —")
    private let weeklyResetLabel = NSTextField(labelWithString: "Weekly Reset: —")
    private let sessionResetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
    private let weeklyResetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return formatter
    }()
    private var report: UsageReport?

    var onRefresh: (() -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: AppConfiguration.contentSize))
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: AppConfiguration.title)
        title.font = .systemFont(ofSize: 12, weight: .bold)
        title.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .right

        let header = makeHeader(title: title)

        for label in [sessionResetLabel, weeklyResetLabel] {
            label.font = .systemFont(ofSize: 10.5, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .left
        }
        let sessionResetRow = makeSessionResetRow()

        configureButton(refreshButton, action: #selector(refreshPressed))
        configureButton(quitButton, action: #selector(quitPressed))

        let footer = NSStackView(views: [weeklyResetLabel, NSView(), refreshButton, quitButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.alignment = .centerY

        guard
            let sessionBar = comparisonBars[.session],
            let allModelsBar = comparisonBars[.allModels],
            let fableBar = comparisonBars[.fable]
        else {
            preconditionFailure("Every configured usage limit requires a comparison bar")
        }

        let sectionDivider = SectionDividerView()
        let stack = NSStackView(views: [
            header,
            sessionBar,
            sessionResetRow,
            sectionDivider,
            allModelsBar,
            fableBar,
            footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 7
        stack.setCustomSpacing(3, after: sessionBar)
        stack.setCustomSpacing(7, after: sessionResetRow)
        stack.setCustomSpacing(8, after: sectionDivider)
        stack.setCustomSpacing(12, after: allModelsBar)
        stack.setCustomSpacing(3, after: fableBar)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: AppConfiguration.contentSize.width),
            root.heightAnchor.constraint(equalToConstant: AppConfiguration.contentSize.height),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -3),
        ])

        view = root
    }

    func showLoading() {
        refreshButton.isEnabled = false
        statusLabel.stringValue = "Updating…"
    }

    func show(report: UsageReport, at date: Date = .now) {
        self.report = report
        refreshButton.isEnabled = true
        statusLabel.stringValue = "Live"
        updateClock(at: date)
    }

    func show(error: Error) {
        report = nil
        refreshButton.isEnabled = true
        statusLabel.stringValue = "Unavailable"
        sessionResetLabel.stringValue = error.localizedDescription
        weeklyResetLabel.stringValue = ""

        for bar in comparisonBars.values {
            bar.showUnavailable()
        }
    }

    func updateClock(at date: Date = .now) {
        guard let report else { return }

        for row in AppConfiguration.rows {
            let snapshot = report[row.limit]
            let timeFraction = snapshot.timeRemainingFraction(at: date)
            let timePercent = snapshot.timeRemainingPercent(at: date)
            let usagePercent = snapshot.usageRemainingPercent
            let color: NSColor

            if usagePercent < 15 {
                color = .systemRed
            } else if usagePercent >= timePercent {
                color = .systemGreen
            } else {
                color = .systemOrange
            }

            comparisonBars[row.limit]?.update(
                timePercent: timePercent,
                timeFraction: timeFraction,
                usagePercent: usagePercent,
                usageFraction: Double(usagePercent) / 100,
                color: color
            )
        }

        sessionResetLabel.stringValue = "Session Reset: \(sessionResetFormatter.string(from: report.session.resetsAt))"
        weeklyResetLabel.stringValue = "Weekly Reset: \(weeklyResetFormatter.string(from: report.allModels.resetsAt))"
    }

    private func makeHeader(title: NSTextField) -> NSView {
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
            statusLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    private func makeSessionResetRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        sessionResetLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(sessionResetLabel)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 14),
            sessionResetLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            sessionResetLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            sessionResetLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
        ])
        return row
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .inline
        button.controlSize = .small
        button.target = self
        button.action = action
    }

    @objc private func refreshPressed() {
        onRefresh?()
    }

    @objc private func quitPressed() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit \(AppConfiguration.appName)?"
        alert.informativeText =
            "The menu-bar indicator will disappear until you open \(AppConfiguration.appName) again."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSApp.terminate(nil)
        }
    }
}
