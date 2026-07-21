import Darwin
import Foundation

@main
enum TestRunner {
    private typealias TestBody = () throws -> Void

    static func main() {
        let tests: [(String, TestBody)] = [
            ("snapshot domain invariants", testSnapshotDomainInvariants),
            ("terminal normalization", testTerminalNormalization),
            ("complete usage report", testCompleteUsageReport),
            ("latest consistent redraw", testLatestConsistentRedraw),
            ("next-day session reset", testNextDaySessionReset),
            ("next-year weekly reset", testNextYearWeeklyReset),
            ("time-zone abbreviation", testTimeZoneAbbreviation),
            ("midnight, noon, optional minutes", testMidnightNoonAndOptionalMinutes),
            ("unknown time zone", testUnknownTimeZone),
            ("invalid percentage", testInvalidPercentage),
            ("invalid clock", testInvalidClock),
            ("impossible calendar date", testImpossibleCalendarDate),
            ("stale session reset", testStaleSessionReset),
            ("stale weekly reset", testStaleWeeklyReset),
            ("incomplete screen", testIncompleteScreen),
            ("independent process timeout", testIndependentProcessTimeout),
            ("bounded process output", testBoundedProcessOutput),
            ("Expect force-stop reaps Claude child", testExpectForceStopReapsChild),
        ]

        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS  \(name)")
            } catch {
                failures += 1
                fputs("FAIL  \(name): \(error)\n", stderr)
            }
        }

        print("\n\(tests.count - failures)/\(tests.count) tests passed")
        if failures > 0 {
            exit(EXIT_FAILURE)
        }
    }

    private static func testSnapshotDomainInvariants() throws {
        let reset = Date(timeIntervalSince1970: 10_000)
        let snapshot = try require(
            UsageSnapshot(usedPercent: 37, windowDuration: 1_000, resetsAt: reset),
            "valid snapshot was rejected"
        )

        try expect(snapshot.usageRemainingPercent == 63)
        try expect(snapshot.timeRemainingFraction(at: reset.addingTimeInterval(-250)) == 0.25)
        try expect(snapshot.timeRemainingPercent(at: reset.addingTimeInterval(-246)) == 25)
        try expect(snapshot.timeRemainingFraction(at: reset.addingTimeInterval(1)) == 0)
        try expect(snapshot.timeRemainingFraction(at: reset.addingTimeInterval(-2_000)) == 1)
        try expect(UsageSnapshot(usedPercent: -1, windowDuration: 1, resetsAt: reset) == nil)
        try expect(UsageSnapshot(usedPercent: 101, windowDuration: 1, resetsAt: reset) == nil)
        try expect(UsageSnapshot(usedPercent: 50, windowDuration: 0, resetsAt: reset) == nil)
    }

    private static func testTerminalNormalization() throws {
        let transcript = "\u{001B}[32mCurrenz\u{08}t\u{001B}[0m\r\nweek\u{0000}\t42"
        try expect(TerminalTranscript.plainText(from: transcript) == "Current\nweek\t42")
        try expect(TerminalTranscript.plainText(from: "\u{08}Claude") == "Claude")
    }

    private static func testCompleteUsageReport() throws {
        let report = try parse(transcript(session: 12, allModels: 34, fable: 56))

        try expect(report.session.usedPercent == 12)
        try expect(report.allModels.usedPercent == 34)
        try expect(report.fable.usedPercent == 56)
        try expect(report.session.resetsAt == date("2026-07-21T01:30:00Z"))
        try expect(report.allModels.resetsAt == date("2026-07-21T23:00:00Z"))
        try expect(report.fable.resetsAt == date("2026-07-22T01:00:00Z"))
    }

    private static func testLatestConsistentRedraw() throws {
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

        try expect(report.session.usedPercent == 41)
        try expect(report.allModels.usedPercent == 52)
        try expect(report.fable.usedPercent == 63)
    }

    private static func testNextDaySessionReset() throws {
        let now = try date("2026-07-21T04:00:00Z")  // July 20 at 9 p.m. Pacific
        let report = try UsageTranscriptParser().parse(
            transcript(sessionReset: "1 am", session: 1, allModels: 2, fable: 3),
            now: now
        )

        try expect(report.session.resetsAt == date("2026-07-21T08:00:00Z"))
    }

    private static func testNextYearWeeklyReset() throws {
        let now = try date("2026-12-31T20:00:00Z")
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

        try expect(report.allModels.resetsAt == date("2027-01-03T00:00:00Z"))
        try expect(report.fable.resetsAt == date("2027-01-03T02:00:00Z"))
    }

    private static func testTimeZoneAbbreviation() throws {
        let text = transcript(session: 1, allModels: 2, fable: 3)
            .replacingOccurrences(of: "America/Los_Angeles", with: "PDT")
        let report = try parse(text)

        try expect(report.session.resetsAt == date("2026-07-21T01:30:00Z"))
    }

    private static func testMidnightNoonAndOptionalMinutes() throws {
        let midnight = try UsageTranscriptParser().parse(
            transcript(sessionReset: "12 am", session: 1, allModels: 2, fable: 3),
            now: date("2026-07-21T03:00:00Z")
        )
        let noon = try UsageTranscriptParser().parse(
            transcript(sessionReset: "12:05 pm", session: 1, allModels: 2, fable: 3),
            now: date("2026-07-21T16:00:00Z")
        )

        try expect(midnight.session.resetsAt == date("2026-07-21T07:00:00Z"))
        try expect(noon.session.resetsAt == date("2026-07-21T19:05:00Z"))
    }

    private static func testUnknownTimeZone() throws {
        let text = transcript(session: 1, allModels: 2, fable: 3)
            .replacingOccurrences(of: "America/Los_Angeles", with: "Mars/Olympus")
        try expectParseError(.unknownTimeZone("Mars/Olympus")) {
            try parse(text)
        }
    }

    private static func testInvalidPercentage() throws {
        try expectParseError(.invalidPercentage) {
            try parse(transcript(session: 101, allModels: 2, fable: 3))
        }
    }

    private static func testInvalidClock() throws {
        try expectParseError(.invalidResetTime) {
            try parse(transcript(sessionReset: "13:72 pm", session: 1, allModels: 2, fable: 3))
        }
    }

    private static func testImpossibleCalendarDate() throws {
        try expectParseError(.invalidResetTime) {
            try parse(
                transcript(
                    weeklyReset: "Feb 31 at 4 pm",
                    session: 1,
                    allModels: 2,
                    fable: 3
                )
            )
        }
    }

    private static func testStaleSessionReset() throws {
        try expectParseError(.invalidResetTime) {
            try parse(transcript(sessionReset: "4 pm", session: 1, allModels: 2, fable: 3))
        }
    }

    private static func testStaleWeeklyReset() throws {
        try expectParseError(.invalidResetTime) {
            try parse(
                transcript(
                    weeklyReset: "Jul 19 at 4 pm",
                    session: 1,
                    allModels: 2,
                    fable: 3
                )
            )
        }
    }

    private static func testIncompleteScreen() throws {
        try expectParseError(.incompleteUsageScreen) {
            try parse("Current session\n10% used")
        }
    }

    private static func testIndependentProcessTimeout() throws {
        let command = ProcessCommand(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment
        )

        do {
            _ = try ProcessRunner(timeout: 0.05).run(command)
            throw TestFailure("expected process timeout")
        } catch ProcessRunnerError.timedOut {
            // Expected: the Swift deadline is independent of Expect's own state timeouts.
        }
    }

    private static func testBoundedProcessOutput() throws {
        let runner = ProcessRunner(timeout: 2, maximumOutputBytes: 1_024)
        let smallCommand = ProcessCommand(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["usage"],
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment
        )
        let result = try runner.run(smallCommand)
        try expect(result.terminationStatus == 0)
        try expect(result.output == "usage\n")

        let command = ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: [],
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment
        )

        do {
            _ = try runner.run(command)
            throw TestFailure("expected output limit error")
        } catch ProcessRunnerError.outputLimitExceeded(let limit) {
            try expect(limit == 1_024)
        }
    }

    private static func testExpectForceStopReapsChild() throws {
        let environment = ProcessInfo.processInfo.environment
        let fakeClaudePath = try require(
            environment["CLAUDE_USAGE_FAKE_EXECUTABLE"],
            "fake Claude executable was not configured"
        )
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helperURL = repositoryURL.appendingPathComponent("Scripts/claude-usage.exp")
        let pidFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-test-\(UUID().uuidString).pid")
        try Data().write(to: pidFileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidFileURL.path)
        defer { try? FileManager.default.removeItem(at: pidFileURL) }

        let command = ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/expect"),
            arguments: [helperURL.path, fakeClaudePath, pidFileURL.path],
            currentDirectoryURL: repositoryURL,
            environment: environment,
            cleanupProcessIDFileURL: pidFileURL
        )

        do {
            _ = try ProcessRunner(timeout: 0.2, maximumOutputBytes: 64 * 1024).run(command)
            throw TestFailure("expected Expect timeout")
        } catch ProcessRunnerError.timedOut {
            // The fake ignores graceful signals, exercising the force-stop path.
        }

        let contents = try String(contentsOf: pidFileURL, encoding: .utf8)
        let childProcessID = try require(
            pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
            "Expect did not record its Claude child"
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while processExists(childProcessID), clock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try expect(!processExists(childProcessID), "Claude child survived forced Expect cleanup")
    }

    private static func parse(_ text: String) throws -> UsageReport {
        try UsageTranscriptParser().parse(text, now: date("2026-07-21T00:00:00Z"))
    }

    private static func transcript(
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

    private static func date(_ value: String) throws -> Date {
        try require(ISO8601DateFormatter().date(from: value), "invalid test date: \(value)")
    }

    private static func expectParseError(
        _ expected: UsageTranscriptParser.ParseError,
        operation: () throws -> UsageReport
    ) throws {
        do {
            _ = try operation()
            throw TestFailure("expected parser error \(expected)")
        } catch let error as UsageTranscriptParser.ParseError {
            try expect(error == expected, "expected \(expected), got \(error)")
        }
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String = "expectation failed",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard try condition() else {
            throw TestFailure("\(file):\(line): \(message)")
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TestFailure(message) }
        return value
    }

    private static func processExists(_ processID: pid_t) -> Bool {
        if kill(processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
