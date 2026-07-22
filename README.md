# Claude Usage Micro

**A tiny macOS menu-bar meter for Claude Code usage.**

See current-session, weekly all-model, and weekly Fable usage without keeping a terminal open.

The colored bars show **usage remaining**. The markers show **time remaining** in each limit window. Green means usage is ahead of the clock, orange means it is behind, and red means less than 15% remains.

The menu-bar item permanently stacks the `Claude` name above its usage gauge. Open the popover and use the gear in its upper-left corner to choose whether the gauge follows the current session, weekly all-model, or weekly Fable limit. The default is the weekly all-model gauge; no numeric percentage is shown in the menu bar.

Each limit is validated independently. If Claude temporarily omits or changes one row, the limits that can still be read remain live and the affected row is marked unavailable. The terminal helper does not depend on model names or headings; known heading, percentage, and reset-time variations are isolated in the tested Swift parser.

If a refresh fails while the last reading is still inside its limit window, the app keeps showing that reading and adds a small orange `S` (stale) badge next to the brand name; the tooltip and popover explain what went wrong. Definitive states — Claude Code not installed, or the helper missing — clear the reading instead.

## Requirements

- macOS 13 or newer
- Apple silicon or Intel (the build targets the host architecture)
- Xcode 16 or newer command line tools (Swift 6)
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

## Development

The app is deliberately small, but its boundaries are explicit:

- The typed usage model, terminal normalization, and transcript parser (`UsageModels.swift`, `TerminalTranscript.swift`, `UsageTranscriptParser.swift`) are AppKit-free and deterministic.
- AppKit presentation, refresh coordination, and the bounded Claude subprocess live beside them in `Sources/` (`AppDelegate.swift`, `UsageViewController.swift`, `ClaudeUsageClient.swift`).
- `Scripts/claude-usage.exp` is the minimal PTY adapter required by Claude's interactive `/usage` command.

For local integrations, run the built executable with `--snapshot`: it prints one `limit_<n>_time_remaining` / `limit_<n>_usage_remaining` / `limit_<n>_resets_at` triple per readable limit (`0` session, `1` weekly all-model, `2` weekly Fable; an unavailable limit is omitted without renumbering the others) and exits non-zero with a compact diagnostic on stderr when usage cannot be read.

Run the complete local check with:

```sh
./test.sh
./build.sh
```

`test.sh` runs strict `swift-format` lint, the dependency-free unit suite, and a full Swift 6 complete-concurrency type-check with warnings treated as errors. `build.sh` produces and verifies an ad-hoc-signed app bundle in `build/`. Both scripts run in CI on macOS.

## Troubleshooting

The menu-bar gauge shows `…` while loading and `!` when usage is unavailable; the tooltip carries the exact error.

- **"Claude Code is not installed"** — the app looks for `claude` in `~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin`, and `/usr/local/bin`, then in every absolute `PATH` entry. Apps launched from Finder inherit a minimal `PATH`, so if `claude` lives under a version manager (nvm, volta, asdf), either symlink it — `ln -s "$(command -v claude)" ~/.local/bin/claude` — or launch the app once from a terminal with `open "build/Claude Usage Micro.app"` so your shell's `PATH` is inherited.
- **Not signed in** — run `claude` once in a terminal and authenticate; the app never handles credentials itself.
- Still stuck? Run `"build/Claude Usage Micro.app/Contents/MacOS/ClaudeUsageMicro" --snapshot` to print the parsed reading or the underlying diagnostic.

## Uninstall

Quit from the popover and delete `build/Claude Usage Micro.app`. To remove the app's saved gauge choice and private workspace:

```sh
defaults delete com.scottflorida.claudeusagemicro
rm -rf ~/Library/Application\ Support/com.scottflorida.claudeusagemicro
```

## Privacy and security

The app has no networking or telemetry code and does not collect or persist Claude credentials; authentication remains handled by the local CLI. It invokes Claude in safe mode, keeps at most 512 KiB of `/usage` transcript in memory, and discards it immediately after parsing. An owner-only temporary file records only the Claude child PID and is removed after cleanup. Claude Code itself may communicate with Anthropic according to its own configuration; stalled, cancelled, or overly verbose helper processes are terminated and reaped under a 100-second process deadline that dominates the helper's own stage timeouts.

## License

[MIT](LICENSE)

Claude Usage Micro is an unofficial utility and is not affiliated with Anthropic.
