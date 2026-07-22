import AppKit
import Foundation

func usageViewControllerTests() -> [TestCase] {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func snapshot(usedPercent: Int, windowDuration: TimeInterval) -> UsageSnapshot {
        guard
            let snapshot = UsageSnapshot(
                usedPercent: usedPercent,
                windowDuration: windowDuration,
                resetsAt: now.addingTimeInterval(windowDuration / 2)
            )
        else {
            preconditionFailure("Invalid UsageSnapshot test fixture")
        }
        return snapshot
    }

    func report(includeFable: Bool) -> UsageReport {
        guard
            let report = UsageReport(
                session: snapshot(usedPercent: 12, windowDuration: 5 * 60 * 60),
                allModels: snapshot(usedPercent: 34, windowDuration: 7 * 24 * 60 * 60),
                fable: includeFable ? snapshot(usedPercent: 56, windowDuration: 7 * 24 * 60 * 60) : nil
            )
        else {
            preconditionFailure("Invalid UsageReport test fixture")
        }
        return report
    }

    @MainActor
    func visibleText(in view: NSView) -> [String] {
        let ownValue = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return ownValue
            + view.subviews
            .filter { !$0.isHidden }
            .flatMap(visibleText(in:))
    }

    return [
        TestCase(name: "popover shows every limit and marks a missing Fable window unavailable") {
            try await MainActor.run {
                _ = NSApplication.shared
                let viewController = UsageViewController()

                viewController.show(report: report(includeFable: true), at: now)
                try expectEqual(viewController.view.frame.size, AppConfiguration.contentSize)
                let fullText = visibleText(in: viewController.view)
                for expected in [
                    "CLAUDE USAGE",
                    "Live",
                    "Session usage remaining",
                    "All-model usage remaining",
                    "Fable usage remaining",
                    "88%",
                    "66%",
                    "44%",
                ] {
                    try expect(fullText.contains(expected), "expected \(expected) in the popover")
                }
                try expect(
                    !fullText.contains("—"),
                    "expected every limit of a complete report to show a reading"
                )

                viewController.show(report: report(includeFable: false), at: now)
                let partialText = visibleText(in: viewController.view)
                try expect(partialText.contains("Partial"), "expected a partial report to be labeled")
                try expect(
                    partialText.contains("—"),
                    "expected the missing Fable window to read as unavailable"
                )
            }
        },
        TestCase(name: "stale data is labeled without discarding the reading") {
            try await MainActor.run {
                _ = NSApplication.shared
                let viewController = UsageViewController()
                viewController.show(
                    report: report(includeFable: true),
                    at: now,
                    status: .stale("Claude did not return usage data in time")
                )
                let text = visibleText(in: viewController.view)
                try expect(text.contains("Stale"), "expected stale data to be labeled")
                try expect(text.contains("88%"), "expected the stale reading to remain visible")
            }
        },
        TestCase(name: "popover error presentation replaces the reading") {
            try await MainActor.run {
                _ = NSApplication.shared
                let viewController = UsageViewController()
                viewController.show(errorMessage: "Claude Code is not installed")
                let text = visibleText(in: viewController.view)
                try expect(text.contains("Unavailable"), "expected the error state to be labeled")
                try expect(
                    text.contains("Claude Code is not installed"),
                    "expected the diagnostic to be visible"
                )
                try expect(text.contains("—"), "expected the bars to show no reading")
            }
        },
        TestCase(name: "comparison bar tolerates a transient zero-width layout") {
            await MainActor.run {
                _ = NSApplication.shared
                let bar = ComparisonBarView(
                    timeLabel: "Time remaining",
                    usageLabel: "Usage remaining",
                    accessibilityLabel: "Test limit"
                )
                bar.frame = .zero
                bar.layoutSubtreeIfNeeded()
            }
        },
    ]
}
