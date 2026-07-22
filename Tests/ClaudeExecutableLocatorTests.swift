import Foundation

func claudeExecutableLocatorTests() -> [TestCase] {
    [
        TestCase(name: "executable locator prefers home candidates over PATH entries") {
            let root = try makeLocatorRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let homeClaude = try makeExecutable(at: root.appendingPathComponent("home/.local/bin/claude"))
            _ = try makeExecutable(at: root.appendingPathComponent("bin/claude"))

            let locator = ClaudeExecutableLocator(
                environment: ["PATH": root.appendingPathComponent("bin").path],
                homeDirectory: root.appendingPathComponent("home", isDirectory: true),
                systemBinDirectories: []
            )
            try expectEqual(locator.find(), homeClaude.resolvingSymlinksInPath())
        },
        TestCase(name: "executable locator skips relative entries, directories, and non-executables") {
            let root = try makeLocatorRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: root.appendingPathComponent("directory-candidate/claude", isDirectory: true),
                withIntermediateDirectories: true
            )
            let plainFile = try makeExecutable(at: root.appendingPathComponent("plain/claude"))
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plainFile.path)
            let usable = try makeExecutable(at: root.appendingPathComponent("usable/claude"))

            let searchPath = [
                "relative-bin",
                ".",
                root.appendingPathComponent("directory-candidate").path,
                root.appendingPathComponent("plain").path,
                root.appendingPathComponent("usable").path,
            ].joined(separator: ":")
            let locator = ClaudeExecutableLocator(
                environment: ["PATH": searchPath],
                homeDirectory: root.appendingPathComponent("home", isDirectory: true),
                systemBinDirectories: []
            )
            try expectEqual(locator.find(), usable.resolvingSymlinksInPath())
        },
        TestCase(name: "executable locator resolves symlinked candidates to their target") {
            let root = try makeLocatorRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = try makeExecutable(at: root.appendingPathComponent("versions/claude-cli"))
            let linkDirectory = root.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: linkDirectory.appendingPathComponent("claude"),
                withDestinationURL: target
            )

            let locator = ClaudeExecutableLocator(
                environment: ["PATH": linkDirectory.path],
                homeDirectory: root.appendingPathComponent("home", isDirectory: true),
                systemBinDirectories: []
            )
            try expectEqual(locator.find(), target.resolvingSymlinksInPath())
        },
        TestCase(name: "executable locator returns nil without a safe candidate") {
            let root = try makeLocatorRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let locator = ClaudeExecutableLocator(
                environment: ["PATH": "relative-bin:."],
                homeDirectory: root.appendingPathComponent("home", isDirectory: true),
                systemBinDirectories: []
            )
            try expectEqual(locator.find(), nil)
        },
    ]
}

private func makeLocatorRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-usage-locator-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("home", isDirectory: true),
        withIntermediateDirectories: true
    )
    return root
}

private func makeExecutable(at url: URL) throws -> URL {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
    else {
        throw TestFailure(description: "could not create an executable fixture at \(url.path)")
    }
    return url
}
