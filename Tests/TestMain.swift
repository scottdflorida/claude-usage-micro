import Darwin
import Foundation

@main
enum TestMain {
    static func main() async {
        var tests = usageModelTests()
        tests.append(contentsOf: refreshFailurePolicyTests())
        tests.append(contentsOf: snapshotOutputTests())
        tests.append(contentsOf: terminalTranscriptTests())
        tests.append(contentsOf: usageTranscriptParserTests())
        tests.append(contentsOf: menuBarTests())
        tests.append(contentsOf: usageViewControllerTests())
        tests.append(contentsOf: claudeExecutableLocatorTests())
        tests.append(contentsOf: processRunnerTests())
        tests.append(contentsOf: claudeUsageClientTests())
        var failures = 0

        for test in tests {
            do {
                try await test.body()
                print("PASS  \(test.name)")
            } catch {
                failures += 1
                fputs("FAIL  \(test.name): \(error)\n", stderr)
            }
        }

        print("\n\(tests.count - failures)/\(tests.count) tests passed")
        if failures > 0 {
            exit(EXIT_FAILURE)
        }
    }
}
