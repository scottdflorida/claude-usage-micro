import Foundation

func terminalTranscriptTests() -> [TestCase] {
    [
        TestCase(name: "terminal normalization strips ANSI, backspaces, and nulls") {
            try expectEqual(
                TerminalTranscript.plainText(from: "\u{001B}[32mCurrenz\u{08}t\u{001B}[0m\r\nweek\u{0000}\t42"),
                "Current\nweek\t42"
            )
            try expectEqual(TerminalTranscript.plainText(from: "\u{08}Claude"), "Claude")
        },
        TestCase(name: "C1 control characters are removed") {
            try expectEqual(TerminalTranscript.plainText(from: "safe\u{9B}31mred"), "safe31mred")
            try expectEqual(TerminalTranscript.plainText(from: "a\u{85}b"), "ab")
        },
        TestCase(name: "terminated OSC sequences cannot swallow usage text") {
            let transcript =
                "\u{001B}]0;title\u{001B}\\Current session\n42% used\n"
                + "Resets 3pm (America/Chicago)\n\u{001B}]0;t2\u{001B}\\tail"
            try expectEqual(
                TerminalTranscript.plainText(from: transcript),
                "Current session\n42% used\nResets 3pm (America/Chicago)\ntail"
            )
            try expectEqual(TerminalTranscript.plainText(from: "before\u{001B}]0;bell\u{07}after"), "beforeafter")
            try expectEqual(
                TerminalTranscript.plainText(
                    from: "\u{001B}]8;;https://example.com\u{001B}\\link\u{001B}]8;;\u{001B}\\"
                ),
                "link"
            )
        },
        TestCase(name: "an unterminated OSC consumes only its own payload") {
            try expectEqual(TerminalTranscript.plainText(from: "kept\u{001B}]0;unterminated"), "kept")
            let hugePayload = "kept\u{001B}]" + String(repeating: "a", count: 100_000)
            try expectEqual(TerminalTranscript.plainText(from: hugePayload), "kept")
        },
        TestCase(name: "repeated unterminated OSC starts stay linear and keep visible text") {
            let transcript = "head" + String(repeating: "\u{001B}]", count: 100_000) + "\u{07}tail"
            let clock = ContinuousClock()
            let start = clock.now
            let plain = TerminalTranscript.plainText(from: transcript)
            let elapsed = clock.now - start
            try expectEqual(plain, "headtail")
            // The pre-fix greedy OSC pattern needed minutes of CPU for this input.
            try expect(elapsed < .seconds(5), "OSC stripping took \(elapsed)")
        },
    ]
}
