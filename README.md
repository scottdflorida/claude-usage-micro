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

To change the automatic refresh cadence, edit [`Sources/RefreshConfiguration.swift`](Sources/RefreshConfiguration.swift) and rebuild.

## License

[MIT](LICENSE)

Claude Usage Micro is an unofficial utility and is not affiliated with Anthropic.
