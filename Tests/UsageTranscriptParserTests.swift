import Foundation

func usageTranscriptParserTests() -> [TestCase] {
    [
        TestCase(name: "complete usage report") {
            let report = try parse(transcript(session: 12, allModels: 34, fable: 56))
            try expectEqual(report.session?.usedPercent, 12)
            try expectEqual(report.allModels?.usedPercent, 34)
            try expectEqual(report.fable?.usedPercent, 56)
            try expectEqual(report.session?.resetsAt, date("2026-07-21T01:30:00Z"))
            try expectEqual(report.allModels?.resetsAt, date("2026-07-21T23:00:00Z"))
            try expectEqual(report.fable?.resetsAt, date("2026-07-22T01:00:00Z"))
        },
        TestCase(name: "Fable can share the all-model reset") {
            let text = transcript(session: 12, allModels: 34, fable: 56)
                .replacingOccurrences(
                    of: "Resets Jul 21 at 6 pm (America/Los_Angeles)\n\nWhat's contributing",
                    with: "What's contributing"
                )
            let report = try parse(text)
            try expectEqual(report.fable?.usedPercent, 56)
            try expectEqual(report.fable?.resetsAt, report.allModels?.resetsAt)
        },
        TestCase(name: "missing limits do not discard valid usage") {
            let text = transcript(session: 12, allModels: 34, fable: 56)
                .replacingOccurrences(
                    of: "Current week (Fable)\n█████ 56% used\nResets Jul 21 at 6 pm (America/Los_Angeles)\n\n",
                    with: "Current week (future model)\n█████ 56% used\n\n"
                )
            let report = try parse(text)
            try expectEqual(report.session?.usedPercent, 12)
            try expectEqual(report.allModels?.usedPercent, 34)
            try expectEqual(report.fable, nil)
            try expect(!report.isComplete, "a two-limit report must not read as complete")
            try expectEqual(report.availableLimits, [.session, .allModels])
        },
        TestCase(name: "weekly-only usage screen") {
            let report = try parse(
                """
                Weekly limit (all models)
                Usage remaining: 66%
                Resets on Tuesday at 4 pm (America/Los_Angeles)
                """
            )
            try expectEqual(report.session, nil)
            try expectEqual(report.allModels?.usedPercent, 34)
            try expectEqual(report.fable, nil)
            try expectEqual(report.availableLimits, [.allModels])
        },
        TestCase(name: "usage wording variants") {
            let text = transcript(session: 12, allModels: 34, fable: 56)
                .replacingOccurrences(of: "Current session", with: "SESSION LIMIT")
                .replacingOccurrences(of: "Current week (all models)", with: "Weekly limit — all model")
                .replacingOccurrences(of: "Current week (Fable)", with: "Weekly (FABLE)")
                .replacingOccurrences(of: "12% used", with: "Used: 12%")
                .replacingOccurrences(of: "34% used", with: "66% remaining")
                .replacingOccurrences(of: "56% used", with: "Consumed 56%")
                .replacingOccurrences(of: "Resets 6:30 pm", with: "Resets at 6:30 pm")
                .replacingOccurrences(of: "Jul 21 at 4 pm", with: "July 21st, at 4 pm")
            let report = try parse(text)
            try expectEqual(report.session?.usedPercent, 12)
            try expectEqual(report.allModels?.usedPercent, 34)
            try expectEqual(report.fable?.usedPercent, 56)
        },
        TestCase(name: "latest consistent redraw") {
            let text = """
                \u{001B}[2J
                \(transcript(session: 1, allModels: 2, fable: 3))
                \u{001B}[H
                \(transcript(session: 41, allModels: 52, fable: 63))
                Current session
                loading…
                Current week (all models)
                loading…
                Current week (Fable)
                loading…
                """
            let report = try parse(text)
            try expectEqual(report.session?.usedPercent, 41)
            try expectEqual(report.allModels?.usedPercent, 52)
            try expectEqual(report.fable?.usedPercent, 63)
        },
        TestCase(name: "capture markers exclude post-usage context") {
            let usage = transcript(session: 12, allModels: 34, fable: 56)
                .replacingOccurrences(of: "█████ 56% used", with: "loading…")
                .replacingOccurrences(of: "What's contributing\nmodel breakdown", with: "")
            let text = """
                \(UsageTranscriptParser.captureBeginMarker)
                \(usage)
                \(UsageTranscriptParser.captureEndMarker)
                $
                Context left: 10%
                """
            let report = try parse(text)
            try expectEqual(report.session?.usedPercent, 12)
            try expectEqual(report.allModels?.usedPercent, 34)
            try expectEqual(report.fable, nil)
        },
        TestCase(name: "prompt boundary excludes context") {
            let usage = transcript(session: 12, allModels: 34, fable: 56)
                .replacingOccurrences(of: "█████ 56% used", with: "loading…")
                .replacingOccurrences(of: "What's contributing\nmodel breakdown", with: "")
            let report = try parse(
                """
                \(usage)
                $
                Context left: 10%
                """
            )
            try expectEqual(report.session?.usedPercent, 12)
            try expectEqual(report.allModels?.usedPercent, 34)
            try expectEqual(report.fable, nil)
        },
        TestCase(name: "partial redraw does not mix windows") {
            let complete = transcript(session: 11, allModels: 22, fable: 33)
                .replacingOccurrences(of: "What's contributing\nmodel breakdown", with: "")
            let text = """
                \(complete)
                Current week (all models)
                82% used
                Resets Jul 21 at 4 pm (America/Los_Angeles)
                Current week (Fable)
                83% used
                Resets Jul 21 at 6 pm (America/Los_Angeles)
                """
            let report = try parse(text)
            try expectEqual(report.session?.usedPercent, 11)
            try expectEqual(report.allModels?.usedPercent, 22)
            try expectEqual(report.fable?.usedPercent, 33)
        },
        TestCase(name: "renamed-session redraw does not mix windows") {
            let complete = transcript(session: 11, allModels: 22, fable: 33)
                .replacingOccurrences(of: "What's contributing\nmodel breakdown", with: "")
            let text = """
                \(complete)
                Five-hour allowance
                81% used
                Resets 6:30 pm (America/Los_Angeles)
                Current week (all models)
                82% used
                Resets Jul 21 at 4 pm (America/Los_Angeles)
                Current week (Fable)
                83% used
                Resets Jul 21 at 6 pm (America/Los_Angeles)
                """
            let report = try parse(text)
            try expectEqual(report.session?.usedPercent, 11)
            try expectEqual(report.allModels?.usedPercent, 22)
            try expectEqual(report.fable?.usedPercent, 33)
        },
        TestCase(name: "next-day session reset") {
            let now = date("2026-07-21T04:00:00Z")  // July 20 at 9 p.m. Pacific
            let report = try UsageTranscriptParser().parse(
                transcript(sessionReset: "1 am", session: 1, allModels: 2, fable: 3),
                now: now
            )
            try expectEqual(report.session?.resetsAt, date("2026-07-21T08:00:00Z"))
        },
        TestCase(name: "next-year weekly reset") {
            let now = date("2026-12-31T20:00:00Z")
            let report = try UsageTranscriptParser().parse(
                transcript(
                    sessionReset: "4 pm",
                    weeklyReset: "Jan 2 at 4 pm",
                    fableReset: "Jan 2 at 6 pm",
                    session: 1,
                    allModels: 2,
                    fable: 3
                ),
                now: now
            )
            try expectEqual(report.allModels?.resetsAt, date("2027-01-03T00:00:00Z"))
            try expectEqual(report.fable?.resetsAt, date("2027-01-03T02:00:00Z"))
        },
        TestCase(name: "weekday weekly reset") {
            let text = transcript(session: 1, allModels: 2, fable: 3)
                .replacingOccurrences(of: "Jul 21 at 4 pm", with: "Tuesday at 4 pm")
                .replacingOccurrences(of: "Jul 21 at 6 pm", with: "Tue 6 pm")
            let report = try parse(text)
            try expectEqual(report.allModels?.resetsAt, date("2026-07-21T23:00:00Z"))
            try expectEqual(report.fable?.resetsAt, date("2026-07-22T01:00:00Z"))
        },
        TestCase(name: "time-zone abbreviation") {
            let text = transcript(session: 1, allModels: 2, fable: 3)
                .replacingOccurrences(of: "America/Los_Angeles", with: "PDT")
            let report = try parse(text)
            try expectEqual(report.session?.resetsAt, date("2026-07-21T01:30:00Z"))
        },
        TestCase(name: "midnight, noon, and optional minutes") {
            let midnight = try UsageTranscriptParser().parse(
                transcript(sessionReset: "12 am", session: 1, allModels: 2, fable: 3),
                now: date("2026-07-21T03:00:00Z")
            )
            let noon = try UsageTranscriptParser().parse(
                transcript(sessionReset: "12:05 pm", session: 1, allModels: 2, fable: 3),
                now: date("2026-07-21T16:00:00Z")
            )
            try expectEqual(midnight.session?.resetsAt, date("2026-07-21T07:00:00Z"))
            try expectEqual(noon.session?.resetsAt, date("2026-07-21T19:05:00Z"))
        },
        TestCase(name: "unknown time zone") {
            let text = transcript(session: 1, allModels: 2, fable: 3)
                .replacingOccurrences(of: "America/Los_Angeles", with: "Mars/Olympus")
            try expectThrows(UsageTranscriptParser.ParseError.unknownTimeZone("Mars/Olympus")) {
                _ = try parse(text)
            }
        },
        TestCase(name: "invalid percentage drops only its own limit") {
            let report = try parse(transcript(session: 101, allModels: 2, fable: 3))
            try expectEqual(report.session, nil)
            try expectEqual(report.allModels?.usedPercent, 2)
            try expectEqual(report.fable?.usedPercent, 3)
        },
        TestCase(name: "fractional percentage is not misread") {
            try expectThrows(UsageTranscriptParser.ParseError.invalidPercentage) {
                _ = try parse(
                    """
                    Weekly limit (all models)
                    34.5% used
                    Resets Jul 21 at 4 pm (America/Los_Angeles)
                    """
                )
            }
        },
        TestCase(name: "invalid clock drops only its own limit") {
            let report = try parse(
                transcript(sessionReset: "13:72 pm", session: 1, allModels: 2, fable: 3)
            )
            try expectEqual(report.session, nil)
            try expect(report.allModels != nil, "expected the weekly limit to survive")
        },
        TestCase(name: "impossible calendar date drops only its own limit") {
            let report = try parse(
                transcript(weeklyReset: "Feb 31 at 4 pm", session: 1, allModels: 2, fable: 3)
            )
            try expect(report.session != nil, "expected the session limit to survive")
            try expectEqual(report.allModels, nil)
            try expect(report.fable != nil, "expected the Fable limit to survive")
        },
        TestCase(name: "stale session reset is rejected") {
            let report = try parse(
                transcript(sessionReset: "4 pm", session: 1, allModels: 2, fable: 3)
            )
            try expectEqual(report.session, nil)
            try expect(report.allModels != nil, "expected the weekly limit to survive")
        },
        TestCase(name: "stale weekly reset is rejected") {
            let report = try parse(
                transcript(weeklyReset: "Jul 19 at 4 pm", session: 1, allModels: 2, fable: 3)
            )
            try expect(report.session != nil, "expected the session limit to survive")
            try expectEqual(report.allModels, nil)
            try expect(report.fable != nil, "expected the Fable limit to survive")
        },
        TestCase(name: "incomplete screen") {
            try expectThrows(UsageTranscriptParser.ParseError.invalidResetTime) {
                _ = try parse("Current session\n10% used")
            }
        },
    ]
}

private func parse(_ text: String) throws -> UsageReport {
    try UsageTranscriptParser().parse(text, now: date("2026-07-21T00:00:00Z"))
}

private func transcript(
    sessionReset: String = "6:30 pm",
    weeklyReset: String = "Jul 21 at 4 pm",
    fableReset: String = "Jul 21 at 6 pm",
    session: Int,
    allModels: Int,
    fable: Int
) -> String {
    """
    Current session
    █████ \(session)% used
    Resets \(sessionReset) (America/Los_Angeles)

    Current week (all models)
    █████ \(allModels)% used
    Resets \(weeklyReset) (America/Los_Angeles)

    Current week (Fable)
    █████ \(fable)% used
    Resets \(fableReset) (America/Los_Angeles)

    What's contributing
    model breakdown
    """
}

private func date(_ value: String) -> Date {
    guard let date = ISO8601DateFormatter().date(from: value) else {
        preconditionFailure("Invalid test date: \(value)")
    }
    return date
}
