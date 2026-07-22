import AppKit

enum UsagePresentationStatus: Equatable, Sendable {
    case current
    case stale(String)
}

@MainActor
final class UsageViewController: NSViewController {
    private let comparisonBars: [UsageLimit: ComparisonBarView] = Dictionary(
        uniqueKeysWithValues: AppConfiguration.rows.map { row in
            (
                row.limit,
                ComparisonBarView(
                    timeLabel: row.timeLabel,
                    usageLabel: row.usageLabel,
                    accessibilityLabel: row.accessibilityLabel
                )
            )
        }
    )
    private let statusLabel = NSTextField(labelWithString: "")
    private let settingsButton = NSButton()
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private let sessionResetLabel = NSTextField(labelWithString: "Session Reset: —")
    private let weeklyResetLabel = NSTextField(labelWithString: "Weekly Reset: —")
    private let sessionResetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter
    }()
    private let weeklyResetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEEjm")
        return formatter
    }()
    private var report: UsageReport?
    private var menuBarPreferences = MenuBarPreferences.standard

    var onRefresh: (() -> Void)?
    var onMenuBarPreferencesChange: ((MenuBarPreferences) -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: AppConfiguration.contentSize))
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: AppConfiguration.title)
        title.font = .systemFont(ofSize: 12, weight: .bold)
        title.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .right

        configureSettingsButton()
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
        _ = view
        refreshButton.isEnabled = false
        statusLabel.stringValue = "Updating…"
    }

    func setMenuBarPreferences(_ preferences: MenuBarPreferences) {
        menuBarPreferences = preferences
    }

    func show(report: UsageReport, at date: Date = .now, status: UsagePresentationStatus = .current) {
        _ = view
        self.report = report
        refreshButton.isEnabled = true
        switch status {
        case .current:
            statusLabel.stringValue = report.isComplete ? "Live" : "Partial"
            statusLabel.toolTip = nil
        case .stale(let diagnostic):
            statusLabel.stringValue = "Stale"
            statusLabel.toolTip = diagnostic
        }
        updateClock(at: date)
    }

    func show(errorMessage: String) {
        _ = view
        report = nil
        refreshButton.isEnabled = true
        statusLabel.stringValue = "Unavailable"
        statusLabel.toolTip = nil
        sessionResetLabel.stringValue = errorMessage
        sessionResetLabel.toolTip = errorMessage
        sessionResetLabel.setAccessibilityValue(errorMessage)
        weeklyResetLabel.stringValue = ""

        for bar in comparisonBars.values {
            bar.showUnavailable()
        }
    }

    func updateClock(at date: Date = .now) {
        guard let report else { return }

        for row in AppConfiguration.rows {
            guard let snapshot = report[row.limit] else {
                comparisonBars[row.limit]?.showUnavailable()
                continue
            }
            let reading = snapshot.reading(at: date)
            comparisonBars[row.limit]?.update(reading: reading, color: reading.pace.color)
        }

        sessionResetLabel.toolTip = nil
        sessionResetLabel.setAccessibilityValue(nil)
        sessionResetLabel.stringValue =
            report.session.map {
                "Session Reset: \(sessionResetFormatter.string(from: $0.resetsAt))"
            } ?? "Session Reset: —"

        let weeklyReset = report.allModels?.resetsAt ?? report.fable?.resetsAt
        weeklyResetLabel.stringValue =
            weeklyReset.map {
                "Weekly Reset: \(weeklyResetFormatter.string(from: $0))"
            } ?? "Weekly Reset: —"
    }

    private func makeHeader(title: NSTextField) -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(settingsButton)
        header.addSubview(title)
        header.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 16),
            settingsButton.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            settingsButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 16),
            settingsButton.heightAnchor.constraint(equalToConstant: 16),
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

    private func configureSettingsButton() {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        settingsButton.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "Menu bar settings"
        )?.withSymbolConfiguration(configuration)
        settingsButton.imagePosition = .imageOnly
        settingsButton.isBordered = false
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(settingsPressed)
        settingsButton.toolTip = "Choose Claude Gauge"
        settingsButton.setAccessibilityLabel("Choose Claude gauge")
    }

    @objc private func refreshPressed() {
        onRefresh?()
    }

    @objc private func settingsPressed(_ sender: NSButton) {
        let menu = NSMenu(title: "Claude Gauge")
        menu.autoenablesItems = false
        menu.addItem(makeSettingsHeading("Usage to Show in the Menu Bar:"))
        menu.addItem(.separator())

        for selection in MenuBarGaugeSelection.allCases {
            let item = NSMenuItem(
                title: selection.title,
                action: #selector(selectGauge(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = selection.rawValue
            item.state = menuBarPreferences.selectedGauge == selection ? .on : .off
            item.isEnabled = report?[selection.usageLimit] != nil || report == nil
            menu.addItem(item)
        }

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.minY - 2),
            in: sender
        )
    }

    private func makeSettingsHeading(_ title: String) -> NSMenuItem {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()

        let height: CGFloat = 28
        let width = max(220, ceil(label.frame.width) + 36)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        label.frame.origin = NSPoint(
            x: 18,
            y: (height - label.frame.height) / 2
        )
        container.addSubview(label)

        let item = NSMenuItem()
        item.view = container
        item.isEnabled = true
        return item
    }

    @objc private func selectGauge(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let selection = MenuBarGaugeSelection(rawValue: rawValue)
        else {
            return
        }
        menuBarPreferences.selectedGauge = selection
        onMenuBarPreferencesChange?(menuBarPreferences)
    }

    @objc private func quitPressed() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit \(AppConfiguration.name)?"
        alert.informativeText =
            "The menu-bar indicator will disappear until you open \(AppConfiguration.name) again."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSApp.terminate(nil)
        }
    }
}

extension UsagePace {
    fileprivate var color: NSColor {
        switch self {
        case .critical:
            .systemRed
        case .onPace:
            .systemGreen
        case .behind:
            .systemOrange
        }
    }
}
