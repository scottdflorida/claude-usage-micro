import Darwin
import Foundation

enum ClaudeUsageClientError: LocalizedError {
    case executableNotFound
    case helperNotFound
    case launchFailed(String)
    case timedOut
    case usageUnavailable

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Claude Code is not installed"
        case .helperNotFound:
            "Claude usage helper is missing"
        case .launchFailed(let message):
            "Could not read Claude usage: \(message)"
        case .timedOut:
            "Claude did not return usage data in time"
        case .usageUnavailable:
            "Claude returned an unfamiliar usage screen"
        }
    }
}

struct ClaudeUsageClient: Sendable {
    private let helperURL: URL?
    private let executableLocator: ClaudeExecutableLocator
    private let runner: ProcessRunner
    private let parser: UsageTranscriptParser

    init(
        helperURL: URL? = Bundle.main.url(forResource: "claude-usage", withExtension: "exp"),
        executableLocator: ClaudeExecutableLocator = ClaudeExecutableLocator(),
        runner: ProcessRunner = ProcessRunner(timeout: 60, maximumOutputBytes: 512 * 1024),
        parser: UsageTranscriptParser = UsageTranscriptParser()
    ) {
        self.helperURL = helperURL
        self.executableLocator = executableLocator
        self.runner = runner
        self.parser = parser
    }

    func fetchUsage() async throws -> UsageReport {
        let worker = Task.detached(priority: .utility) {
            try fetchUsageSynchronously()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func fetchUsageSynchronously() throws -> UsageReport {
        guard let executableURL = executableLocator.find() else {
            throw ClaudeUsageClientError.executableNotFound
        }
        guard let helperURL else {
            throw ClaudeUsageClientError.helperNotFound
        }

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        // Parsing intentionally targets Claude's English screen-reader labels.
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"

        let fileManager = FileManager.default
        let childPIDFileURL = fileManager.temporaryDirectory
            .appendingPathComponent("claude-usage-child-\(UUID().uuidString)")
            .appendingPathExtension("pid")
        guard
            fileManager.createFile(
                atPath: childPIDFileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw ClaudeUsageClientError.launchFailed("Could not create the child-process record")
        }
        defer { try? fileManager.removeItem(at: childPIDFileURL) }

        let command = ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/expect"),
            arguments: [helperURL.path, executableURL.path, childPIDFileURL.path],
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            environment: environment,
            cleanupProcessIDFileURL: childPIDFileURL
        )

        let result: ProcessResult
        do {
            result = try runner.run(command)
        } catch is CancellationError {
            throw CancellationError()
        } catch ProcessRunnerError.timedOut {
            throw ClaudeUsageClientError.timedOut
        } catch {
            throw ClaudeUsageClientError.launchFailed(error.localizedDescription)
        }

        guard result.terminationStatus == 0 else {
            let diagnostic = failureDiagnostic(from: result.output)
            let detail =
                diagnostic.isEmpty
                ? "exit \(result.terminationStatus)"
                : diagnostic
            throw ClaudeUsageClientError.launchFailed(detail)
        }

        do {
            return try parser.parse(result.output)
        } catch {
            throw ClaudeUsageClientError.usageUnavailable
        }
    }

    private func failureDiagnostic(from transcript: String) -> String {
        TerminalTranscript.plainText(from: transcript)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(3)
            .joined(separator: " · ")
            .prefix(240)
            .description
    }
}

struct ClaudeExecutableLocator: Sendable {
    private let environment: [String: String]
    private let homeDirectory: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func find(fileManager: FileManager = .default) -> URL? {
        var candidates = [
            homeDirectory.appendingPathComponent(".local/bin/claude").path,
            homeDirectory.appendingPathComponent(".claude/local/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let path = environment["PATH"] {
            candidates.append(
                contentsOf: path.split(separator: ":").map {
                    URL(fileURLWithPath: String($0)).appendingPathComponent("claude").path
                })
        }

        var visited = Set<String>()
        for path in candidates where visited.insert(path).inserted {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path).resolvingSymlinksInPath()
            }
        }
        return nil
    }
}

struct ProcessCommand: Sendable {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL
    let environment: [String: String]
    let cleanupProcessIDFileURL: URL?

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String],
        cleanupProcessIDFileURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.cleanupProcessIDFileURL = cleanupProcessIDFileURL
    }
}

struct ProcessResult: Sendable {
    let terminationStatus: Int32
    let output: String
}

enum ProcessRunnerError: LocalizedError {
    case launchFailed(String)
    case outputLimitExceeded(Int)
    case pipeFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            message
        case .outputLimitExceeded(let limit):
            "The helper produced more than \(limit) bytes of output"
        case .pipeFailed(let message):
            "Could not read helper output: \(message)"
        case .timedOut:
            "The helper process timed out"
        }
    }
}

struct ProcessRunner: Sendable {
    let timeout: TimeInterval
    let maximumOutputBytes: Int

    init(timeout: TimeInterval, maximumOutputBytes: Int = 512 * 1024) {
        precondition(timeout > 0)
        precondition(maximumOutputBytes > 0)
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }

    func run(_ command: ProcessCommand) throws -> ProcessResult {
        try Task.checkCancellation()

        let outputPipe = Pipe()
        let readHandle = outputPipe.fileHandleForReading
        let writeHandle = outputPipe.fileHandleForWriting
        defer { try? readHandle.close() }
        defer { try? writeHandle.close() }

        let descriptor = readHandle.fileDescriptor
        let currentFlags = fcntl(descriptor, F_GETFL)
        guard currentFlags >= 0, fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) >= 0 else {
            throw ProcessRunnerError.pipeFailed(String(cString: strerror(errno)))
        }

        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectoryURL
        process.environment = command.environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }
        try? writeHandle.close()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var output = Data()
        while process.isRunning {
            do {
                try drain(descriptor, into: &output)
            } catch {
                stop(process, cleanupProcessIDFileURL: command.cleanupProcessIDFileURL)
                throw error
            }
            if Task.isCancelled {
                stop(process, cleanupProcessIDFileURL: command.cleanupProcessIDFileURL)
                throw CancellationError()
            }
            if clock.now >= deadline {
                stop(process, cleanupProcessIDFileURL: command.cleanupProcessIDFileURL)
                throw ProcessRunnerError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        try drain(descriptor, into: &output)

        return ProcessResult(
            terminationStatus: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self)
        )
    }

    private func drain(_ descriptor: Int32, into output: inout Data) throws {
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)

        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead > 0 {
                guard output.count + bytesRead <= maximumOutputBytes else {
                    throw ProcessRunnerError.outputLimitExceeded(maximumOutputBytes)
                }
                output.append(contentsOf: buffer[..<bytesRead])
            } else if bytesRead == 0 {
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                throw ProcessRunnerError.pipeFailed(String(cString: strerror(errno)))
            }
        }
    }

    private func stop(_ process: Process, cleanupProcessIDFileURL: URL?) {
        let clock = ContinuousClock()
        var cleanupProcessID = readCleanupProcessID(from: cleanupProcessIDFileURL, excluding: process.processIdentifier)
        let identifierWaitDeadline = clock.now.advanced(by: .milliseconds(100))
        while cleanupProcessID == nil, process.isRunning, clock.now < identifierWaitDeadline {
            Thread.sleep(forTimeInterval: 0.005)
            cleanupProcessID = readCleanupProcessID(from: cleanupProcessIDFileURL, excluding: process.processIdentifier)
        }

        if process.isRunning {
            process.terminate()
        }
        if let cleanupProcessID, processExists(cleanupProcessID) {
            kill(cleanupProcessID, SIGTERM)
        }

        let gracePeriodDeadline = clock.now.advanced(by: .seconds(1))
        while process.isRunning || cleanupProcessID.map(processExists) == true, clock.now < gracePeriodDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        if let cleanupProcessID, processExists(cleanupProcessID) {
            kill(cleanupProcessID, SIGKILL)
        }
        process.waitUntilExit()

        let forceStopDeadline = clock.now.advanced(by: .milliseconds(250))
        while cleanupProcessID.map(processExists) == true, clock.now < forceStopDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func readCleanupProcessID(from url: URL?, excluding runnerProcessID: pid_t) -> pid_t? {
        guard
            let url,
            let contents = try? String(contentsOf: url, encoding: .utf8),
            let processID = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
            processID > 1,
            processID != runnerProcessID,
            processID != getpid()
        else {
            return nil
        }
        return processID
    }

    private func processExists(_ processID: pid_t) -> Bool {
        if kill(processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}
