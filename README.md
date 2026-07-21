# Claude Usage Micro

**A tiny macOS menu-bar meter for Claude Code usage.**

See current-session, weekly all-model, and weekly Fable usage without keeping a terminal open.

The colored bars show **usage remaining**. The white markers show **time remaining** in each limit window. Green means usage is ahead of the clock, orange means it is behind, and red means less than 15% remains.

## Requirements

- macOS 13 or newer
- Apple silicon
- Xcode command line tools
- An authenticated Claude Code CLI
- `expect` (included with macOS)

## Build and run

```sh
git clone https://github.com/scottdflorida/claude-usage-micro.git
cd claude-usage-micro
./build.sh
open "build/Claude Usage Micro.app"
```

No API key, server, database, package manager, or external dependency is required. Every 15 minutes, the app starts a short-lived local Claude Code session in safe mode, reads `/usage` through a pseudo-terminal, and exits. It sends no telemetry of its own.

To change the automatic refresh cadence, edit [`Sources/App/AppConfiguration.swift`](Sources/App/AppConfiguration.swift) and rebuild.

## Development

The app is deliberately small, but its boundaries are explicit:

- `Sources/Core` contains the typed usage model, terminal normalization, and transcript parser.
- `Sources/App` owns AppKit presentation, refresh coordination, and the bounded Claude subprocess.
- `Scripts/claude-usage.exp` is the minimal PTY adapter required by Claude's interactive `/usage` command.

Run the deterministic parser and domain test suite with:

```sh
./test.sh
```

The build uses Swift 6 strict concurrency checks and treats warnings as errors. The helper runs Claude in safe mode, enforces an overall 60-second process deadline, and bounds captured output.

## Privacy and security

The app has no networking or telemetry code and does not collect or persist Claude credentials; authentication remains handled by the local CLI. It invokes Claude in safe mode, keeps at most 512 KiB of `/usage` transcript in memory, and discards it immediately after parsing. An owner-only temporary file records only the Claude child PID and is removed after cleanup. Claude Code itself may communicate with Anthropic according to its own configuration; stalled, cancelled, or overly verbose helper processes are terminated and reaped.

## License

[MIT](LICENSE)

Claude Usage Micro is an unofficial utility and is not affiliated with Anthropic.
