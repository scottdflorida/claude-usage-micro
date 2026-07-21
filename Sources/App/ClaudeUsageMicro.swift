import AppKit

@main
@MainActor
enum ClaudeUsageMicroMain {
    static func main() {
        if CommandLine.arguments.contains("--snapshot") {
            printSnapshot()
            return
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }

    private static func printSnapshot() {
        do {
            let report = try ClaudeUsageClient().fetchUsageSynchronously()
            let now = Date.now
            for (index, snapshot) in [report.session, report.allModels, report.fable].enumerated() {
                print("limit_\(index)_time_remaining=\(snapshot.timeRemainingPercent(at: now))")
                print("limit_\(index)_usage_remaining=\(snapshot.usageRemainingPercent)")
                print("limit_\(index)_resets_at=\(Int(snapshot.resetsAt.timeIntervalSince1970))")
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
