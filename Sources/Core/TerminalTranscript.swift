import Foundation

enum TerminalTranscript {
    private static let ansiEscapeExpression = try? NSRegularExpression(
        pattern: #"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\)|[()][A-Z0-9]|.)"#
    )

    /// Removes terminal control sequences while retaining the visible text emitted by a PTY.
    static func plainText(from transcript: String) -> String {
        let fullRange = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        let withoutANSI =
            ansiEscapeExpression?.stringByReplacingMatches(
                in: transcript,
                range: fullRange,
                withTemplate: ""
            ) ?? transcript

        let normalizedLines =
            withoutANSI
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var visibleScalars = String.UnicodeScalarView()
        for scalar in normalizedLines.unicodeScalars {
            switch scalar.value {
            case 0x08, 0x7F:
                if let last = visibleScalars.last, last.value != 0x0A {
                    visibleScalars.removeLast()
                }
            case 0x0A, 0x09, 0x20...:
                visibleScalars.append(scalar)
            default:
                continue
            }
        }
        return String(visibleScalars)
    }
}
