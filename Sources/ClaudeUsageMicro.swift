import AppKit

@main
@MainActor
enum ClaudeUsageMicro {
    private static var appDelegate: AppDelegate?

    static func main() {
        if CommandLine.arguments.contains("--snapshot") {
            printSnapshot()
            return
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        application.delegate = delegate
        application.run()
    }

    private static func printSnapshot() {
        do {
            let report = try ClaudeUsageClient().fetchUsageSynchronously()
            for line in SnapshotOutput.lines(for: report) {
                print(line)
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
