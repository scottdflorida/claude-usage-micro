import Foundation

func claudeUsageClientTests() -> [TestCase] {
    [
        TestCase(name: "the private usage workspace lives in Application Support") {
            let workspaceURL = ClaudeUsageWorkspace.defaultURL()
            let expectedSuffix =
                "/Library/Application Support/"
                + MenuBarPreferencesStore.suiteName
                + "/UsageWorkspace"
            try expect(
                workspaceURL.path.hasSuffix(expectedSuffix),
                "unexpected workspace path \(workspaceURL.path)"
            )
            try expect(!workspaceURL.path.contains("/Documents/"), "workspace must avoid user documents")
        },
        TestCase(name: "failure diagnostics keep the last three sanitized lines") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            try expectEqual(
                ClaudeUsageClient().failureDiagnostic(
                    from: "one\r\n\r\n  two  \r\nthree\r\nError in \(home)/project\r\n"
                ),
                "two · three · Error in ~/project"
            )
        },
        TestCase(name: "failure diagnostics strip terminal control sequences") {
            try expectEqual(
                ClaudeUsageClient().failureDiagnostic(from: "safe\u{9B}31mred\u{1B}[0m\nsecond"),
                "safe31mred · second"
            )
        },
        TestCase(name: "failure diagnostics are capped at 240 characters") {
            let diagnostic = ClaudeUsageClient().failureDiagnostic(
                from: String(repeating: "x", count: 300)
            )
            try expectEqual(diagnostic.count, 240)
            try expect(diagnostic.allSatisfy { $0 == "x" }, "expected the capped transcript prefix")
        },
        TestCase(name: "fetches a complete usage report from a fake Claude end to end") {
            let root = try makeClientRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try installClaude(copying: fixtureExecutablePath("CLAUDE_USAGE_FAKE_USAGE_EXECUTABLE"), in: root)

            let started = Date()
            let report = try makeClient(root: root).fetchUsageSynchronously()
            try expectEqual(report.session?.usedPercent, 37)
            try expectEqual(report.allModels?.usedPercent, 25)
            try expectEqual(report.fable?.usedPercent, 56)
            try expectEqual(report.fable?.resetsAt, report.allModels?.resetsAt)
            try expect(report.isComplete, "expected all three limits to be reported")

            guard let sessionReset = report.session?.resetsAt, let weeklyReset = report.allModels?.resetsAt
            else {
                throw TestFailure(description: "expected parsed reset dates")
            }
            // The fake resets its session two hours out and its week three days out.
            let sessionRemaining = sessionReset.timeIntervalSince(started)
            try expect(
                abs(sessionRemaining - 2 * 60 * 60) < 15 * 60,
                "unexpected session reset distance \(sessionRemaining)"
            )
            let weeklyRemaining = weeklyReset.timeIntervalSince(started)
            try expect(
                abs(weeklyRemaining - 3 * 24 * 60 * 60) < 15 * 60,
                "unexpected weekly reset distance \(weeklyRemaining)"
            )
        },
        TestCase(name: "an unfamiliar usage screen maps to usageUnavailable") {
            let root = try makeClientRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try installClaude(copying: fixtureExecutablePath("CLAUDE_USAGE_FAKE_TRUST_EXECUTABLE"), in: root)

            do {
                _ = try makeClient(root: root).fetchUsageSynchronously()
                throw TestFailure(description: "expected an unparseable screen to fail")
            } catch ClaudeUsageClientError.usageUnavailable {
                // Expected: the trust fixture renders a screen without reset lines.
            }
        },
        TestCase(name: "a failing launch surfaces the helper diagnostic") {
            let root = try makeClientRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try installClaude(script: "#!/bin/sh\nexit 9\n", in: root)

            do {
                _ = try makeClient(root: root).fetchUsageSynchronously()
                throw TestFailure(description: "expected a failing claude to be reported")
            } catch ClaudeUsageClientError.launchFailed(let detail) {
                try expectEqual(detail, "Claude Code exited before showing its prompt")
            }
        },
        TestCase(name: "a hung Claude maps to timedOut") {
            let root = try makeClientRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try installClaude(script: "#!/bin/sh\nsleep 30\n", in: root)

            do {
                _ = try makeClient(root: root, timeout: 0.5).fetchUsageSynchronously()
                throw TestFailure(description: "expected the runner deadline to fire")
            } catch ClaudeUsageClientError.timedOut {
                // Expected.
            }
        },
        TestCase(name: "a missing executable maps to executableNotFound") {
            let root = try makeClientRoot()
            defer { try? FileManager.default.removeItem(at: root) }

            do {
                _ = try makeClient(root: root).fetchUsageSynchronously()
                throw TestFailure(description: "expected an empty PATH to fail")
            } catch ClaudeUsageClientError.executableNotFound {
                // Expected.
            }
        },
        TestCase(name: "a missing helper maps to helperNotFound") {
            let root = try makeClientRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try installClaude(script: "#!/bin/sh\nexit 0\n", in: root)

            do {
                _ = try makeClient(root: root, helperURL: nil).fetchUsageSynchronously()
                throw TestFailure(description: "expected a missing helper to fail")
            } catch ClaudeUsageClientError.helperNotFound {
                // Expected.
            }
        },
        TestCase(name: "an unusable workspace maps to a launch failure") {
            let root = try makeClientRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try installClaude(script: "#!/bin/sh\nexit 0\n", in: root)
            let blocker = root.appendingPathComponent("blocker")
            guard FileManager.default.createFile(atPath: blocker.path, contents: Data()) else {
                throw TestFailure(description: "could not create the workspace blocker")
            }

            do {
                _ = try makeClient(
                    root: root,
                    workspaceURL: blocker.appendingPathComponent("workspace", isDirectory: true)
                ).fetchUsageSynchronously()
                throw TestFailure(description: "expected workspace preparation to fail")
            } catch ClaudeUsageClientError.launchFailed(let detail) {
                try expectEqual(detail, "Could not prepare the app's private usage workspace")
            }
        },
    ]
}

private func fixtureExecutablePath(_ key: String) throws -> String {
    guard let path = ProcessInfo.processInfo.environment[key] else {
        throw TestFailure(description: "\(key) was not configured")
    }
    return path
}

private func helperScriptURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Scripts/claude-usage.exp")
}

private func makeClientRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-usage-client-\(UUID().uuidString)", isDirectory: true)
    for subdirectory in ["bin", "home"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(subdirectory, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
    return root
}

private func installClaude(copying sourcePath: String, in root: URL) throws {
    try FileManager.default.copyItem(
        at: URL(fileURLWithPath: sourcePath),
        to: root.appendingPathComponent("bin/claude")
    )
}

private func installClaude(script: String, in root: URL) throws {
    let created = FileManager.default.createFile(
        atPath: root.appendingPathComponent("bin/claude").path,
        contents: Data(script.utf8),
        attributes: [.posixPermissions: 0o755]
    )
    try expect(created, "could not install the fake claude script")
}

private func makeClient(
    root: URL,
    helperURL: URL? = helperScriptURL(),
    workspaceURL: URL? = nil,
    timeout: TimeInterval = 15
) -> ClaudeUsageClient {
    ClaudeUsageClient(
        helperURL: helperURL,
        workspaceURL: workspaceURL ?? root.appendingPathComponent("workspace", isDirectory: true),
        executableLocator: ClaudeExecutableLocator(
            environment: ["PATH": root.appendingPathComponent("bin", isDirectory: true).path],
            homeDirectory: root.appendingPathComponent("home", isDirectory: true),
            systemBinDirectories: []
        ),
        runner: ProcessRunner(timeout: timeout)
    )
}
