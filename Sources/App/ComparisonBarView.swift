import AppKit

@MainActor
final class ComparisonBarView: NSView {
    private let timeName: NSTextField
    private let timeValue = NSTextField(labelWithString: "—")
    private let usageName: NSTextField
    private let usageValue = NSTextField(labelWithString: "—")

    private var timeFraction = 0.0
    private var usageFraction = 0.0
    private var usageColor = NSColor.systemGray
    private var trackRect = NSRect.zero
    private var isAvailable = false

    init(timeLabel: String, usageLabel: String) {
        timeName = NSTextField(labelWithString: timeLabel)
        usageName = NSTextField(labelWithString: usageLabel)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        timeName.font = .systemFont(ofSize: 12, weight: .medium)
        usageName.font = .systemFont(ofSize: 12, weight: .bold)
        for label in [timeName, usageName] {
            label.textColor = .secondaryLabelColor
            addSubview(label)
        }

        for label in [timeValue, usageValue] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            label.alignment = .center
            addSubview(label)
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(usageLabel) compared with \(timeLabel)")
        setAccessibilityHelp("The colored bar shows usage remaining; the marker shows time remaining.")
        for label in [timeName, timeValue, usageName, usageValue] {
            label.setAccessibilityElement(false)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

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
            name: timeName,
            value: timeValue,
            fraction: timeFraction,
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
        let trackColor =
            isDark
            ? NSColor.white.withAlphaComponent(0.24)
            : NSColor.black.withAlphaComponent(0.14)
        trackColor.setFill()
        trackPath.fill()
        guard isAvailable else { return }

        NSGraphicsContext.saveGraphicsState()
        trackPath.addClip()
        usageColor.setFill()
        NSBezierPath(
            rect: NSRect(
                x: trackRect.minX,
                y: trackRect.minY,
                width: trackRect.width * usageFraction,
                height: trackRect.height
            )
        ).fill()
        NSGraphicsContext.restoreGraphicsState()

        let markerWidth: CGFloat = 3
        let rawMarkerX = trackRect.minX + trackRect.width * timeFraction
        let markerX = max(
            trackRect.minX,
            min(trackRect.maxX - markerWidth, rawMarkerX - markerWidth / 2)
        )
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: markerX,
                y: trackRect.minY - 2,
                width: markerWidth,
                height: trackRect.height + 4
            ),
            xRadius: 1.5,
            yRadius: 1.5
        ).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func update(
        timePercent: Int,
        timeFraction: Double,
        usagePercent: Int,
        usageFraction: Double,
        color: NSColor
    ) {
        self.timeFraction = timeFraction.clampedToUnitInterval
        self.usageFraction = usageFraction.clampedToUnitInterval
        usageColor = color
        isAvailable = true
        timeValue.stringValue = "\(timePercent)%"
        usageValue.stringValue = "\(usagePercent)%"
        setAccessibilityValue(
            "Time remaining \(timePercent) percent, usage remaining \(usagePercent) percent"
        )
        needsLayout = true
        needsDisplay = true
    }

    func showUnavailable() {
        timeFraction = 0
        usageFraction = 0
        usageColor = .systemGray
        isAvailable = false
        timeValue.stringValue = "—"
        usageValue.stringValue = "—"
        setAccessibilityValue("Usage unavailable")
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
        let markerCenter = bounds.minX + bounds.width * fraction
        let valueX = max(
            bounds.minX,
            min(bounds.maxX - valueWidth, markerCenter - valueWidth / 2)
        )
        value.frame = NSRect(x: valueX, y: y, width: valueWidth, height: rowHeight)

        let nameWidth = name.frame.width
        let gap: CGFloat = 2.5
        if fraction > 0.5 {
            name.alignment = .right
            name.frame = NSRect(
                x: max(bounds.minX, value.frame.minX - gap - nameWidth),
                y: y,
                width: nameWidth,
                height: rowHeight
            )
        } else {
            name.alignment = .left
            name.frame = NSRect(
                x: min(bounds.maxX - nameWidth, value.frame.maxX + gap),
                y: y,
                width: nameWidth,
                height: rowHeight
            )
        }
    }
}

extension Double {
    fileprivate var clampedToUnitInterval: Double {
        min(1, max(0, self))
    }
}
