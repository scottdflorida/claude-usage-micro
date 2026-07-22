import Darwin
import Foundation

func processRunnerTests() -> [TestCase] {
    [
        TestCase(name: "independent process timeout") {
            let command = ProcessCommand(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                currentDirectoryURL: FileManager.default.temporaryDirectory,
                environment: ProcessInfo.processInfo.environment
            )
            do {
                _ = try ProcessRunner(timeout: 0.05).run(command)
                throw TestFailure(description: "expected process timeout")
            } catch ProcessRunnerError.timedOut {
                // Expected: the Swift deadline is independent of Expect's own state timeouts.
            }
        },
        TestCase(name: "bounded process output") {
            let runner = ProcessRunner(timeout: 2, maximumOutputBytes: 1_024)
            let smallCommand = ProcessCommand(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["usage"],
                currentDirectoryURL: FileManager.default.temporaryDirectory,
                environment: ProcessInfo.processInfo.environment
            )
            let result = try runner.run(smallCommand)
            try expectEqual(result.terminationStatus, 0)
            try expectEqual(result.output, "usage\n")

            let command = ProcessCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
                arguments: [],
                currentDirectoryURL: FileManager.default.temporaryDirectory,
                environment: ProcessInfo.processInfo.environment
            )
            do {
                _ = try runner.run(command)
                throw TestFailure(description: "expected output limit error")
            } catch ProcessRunnerError.outputLimitExceeded(let limit) {
                try expectEqual(limit, 1_024)
            }
        },
        TestCase(name: "cooperative cancellation interrupts a run promptly") {
            let command = ProcessCommand(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                currentDirectoryURL: FileManager.default.temporaryDirectory,
                environment: ProcessInfo.processInfo.environment
            )
            let clock = ContinuousClock()
            let start = clock.now
            let worker = Task.detached {
                try ProcessRunner(timeout: 10).run(command)
            }
            try await Task.sleep(for: .milliseconds(50))
            worker.cancel()
            do {
                _ = try await worker.value
                throw TestFailure(description: "expected the run to observe cancellation")
            } catch is CancellationError {
                // Expected.
            }
            let elapsed = clock.now - start
            try expect(elapsed < .seconds(3), "cancellation returned only after \(elapsed)")
        },
        TestCase(name: "abnormal helper exit reaps the recorded child") {
            let pidFileURL = try makeChildPIDFile()
            defer { cleanUpRecordedChildForTest(pidFileURL) }
            let result = try ProcessRunner(timeout: 3).run(
                try orphaningCommand(mode: "abnormal", pidFileURL: pidFileURL)
            )
            try expectEqual(result.terminationStatus, 17)
            try await expectRecordedChildWasReaped(pidFileURL)
        },
        TestCase(name: "final output-limit drain reaps the recorded child") {
            let pidFileURL = try makeChildPIDFile()
            defer { cleanUpRecordedChildForTest(pidFileURL) }
            do {
                _ = try ProcessRunner(timeout: 3, maximumOutputBytes: 128).run(
                    try orphaningCommand(mode: "output-limit", pidFileURL: pidFileURL)
                )
                throw TestFailure(description: "expected final-drain output limit error")
            } catch ProcessRunnerError.outputLimitExceeded(let limit) {
                try expectEqual(limit, 128)
            }
            try await expectRecordedChildWasReaped(pidFileURL)
        },
        TestCase(name: "Expect force-stop reaps the Claude child") {
            let environment = ProcessInfo.processInfo.environment
            guard let fakeClaudePath = environment["CLAUDE_USAGE_FAKE_EXECUTABLE"] else {
                throw TestFailure(description: "fake Claude executable was not configured")
            }
            let helperURL = repositoryRootURL().appendingPathComponent("Scripts/claude-usage.exp")
            let pidFileURL = try makeChildPIDFile()
            defer { cleanUpRecordedChildForTest(pidFileURL) }

            let command = ProcessCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/expect"),
                arguments: [helperURL.path, fakeClaudePath, pidFileURL.path],
                currentDirectoryURL: FileManager.default.temporaryDirectory,
                environment: environment,
                cleanupProcessIDFileURL: pidFileURL
            )
            let worker = Task.detached {
                try ProcessRunner(timeout: 30, maximumOutputBytes: 64 * 1_024).run(command)
            }
            defer { worker.cancel() }

            // Force the stop only once the helper has recorded its child, so the reaping
            // assertion cannot race Tcl startup on a loaded machine.
            let childProcessID = try await recordedChildProcessID(in: pidFileURL, within: .seconds(10))
            worker.cancel()
            do {
                _ = try await worker.value
                throw TestFailure(description: "expected the forced stop to interrupt the helper")
            } catch is CancellationError {
                // The fake ignores graceful signals, exercising the force-stop path.
            }
            try await expectProcessExit(
                childProcessID,
                within: .seconds(2),
                message: "Claude child survived forced Expect cleanup"
            )
        },
    ]
}

private func repositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func processExists(_ processID: pid_t) -> Bool {
    if kill(processID, 0) == 0 {
        return true
    }
    return errno == EPERM
}

private func makeChildPIDFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-usage-orphan-test-\(UUID().uuidString).pid")
    try Data().write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
}

private func orphaningCommand(mode: String, pidFileURL: URL) throws -> ProcessCommand {
    guard let executable = ProcessInfo.processInfo.environment["CLAUDE_USAGE_ORPHANING_HELPER"] else {
        throw TestFailure(description: "orphaning helper was not configured")
    }
    return ProcessCommand(
        executableURL: URL(fileURLWithPath: executable),
        arguments: [pidFileURL.path, mode],
        currentDirectoryURL: FileManager.default.temporaryDirectory,
        environment: ProcessInfo.processInfo.environment,
        cleanupProcessIDFileURL: pidFileURL
    )
}

private func recordedChildProcessID(in pidFileURL: URL, within limit: Duration) async throws -> pid_t {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while clock.now < deadline {
        if let contents = try? String(contentsOf: pidFileURL, encoding: .utf8),
            let processID = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return processID
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TestFailure(description: "the helper did not record its child in time")
}

private func expectRecordedChildWasReaped(_ pidFileURL: URL) async throws {
    let contents = try String(contentsOf: pidFileURL, encoding: .utf8)
    guard let processID = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw TestFailure(description: "helper did not record its child")
    }
    try await expectProcessExit(
        processID,
        within: .seconds(1),
        message: "recorded child survived helper cleanup"
    )
}

private func expectProcessExit(_ processID: pid_t, within limit: Duration, message: String) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while processExists(processID), clock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try expect(!processExists(processID), message)
}

private func cleanUpRecordedChildForTest(_ pidFileURL: URL) {
    defer { try? FileManager.default.removeItem(at: pidFileURL) }
    guard
        let contents = try? String(contentsOf: pidFileURL, encoding: .utf8),
        let processID = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
        processID > 1,
        processID != getpid(),
        processExists(processID)
    else {
        return
    }
    kill(processID, SIGKILL)
}
