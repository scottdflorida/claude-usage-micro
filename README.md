# Claude Usage Micro

## A tiny macOS menu-bar meter for Claude Code usage.
- No API key or separate login required
- No third-party dependencies
- I have daily release-notes watch and canary probes running so I can quickly react and update this app whenever they change how usage data is exposed

***Get the companion meters for [Cursor/Grok](https://github.com/scottdflorida/cursor-usage-micro) and
[Codex](https://github.com/scottdflorida/codex-usage-micro)!*** *(So you can always see which services still have
usage remaining.)*  
<img width="470" height="37" alt="image" src="https://github.com/user-attachments/assets/99cdc56b-7ca3-4a0d-8a10-9dd10f2d9f45" /> 

The purpose is to show you **how your usage is draining compared to the time left in each limit window**.  
The vertical marker inside the meter moves from right to left as the window progresses.  
The fill drains as usage is consumed.
- Green when remaining usage exceeds remaining time
- Amber when remaining usage is less than remaining time
- Red when remaining usage is less than 15%

Claude reports current-session, weekly all-model, and weekly Fable limits. Open the popover and use the gear to
choose which limit appears in the menu bar; weekly all-model usage is the default.

In the menu bar: meter at a glance  
<img width="64" height="35" alt="image" src="https://github.com/user-attachments/assets/18f50630-fa42-4b98-a459-f6f87221ed40" />

On hover: the data that matters  
<img width="345" height="102" alt="image" src="https://github.com/user-attachments/assets/8a24772f-a7c4-43d6-b667-5f5565f45549" />

On click: the full view  
<img width="358" height="368" alt="image" src="https://github.com/user-attachments/assets/832caf69-846f-4f31-a36f-0ecd276ccb07" />


## Requirements

- macOS 13 or newer
- Apple silicon or Intel; the build targets the host architecture
- A Swift 6.2-capable Xcode toolchain (Xcode 26 or newer)
- An authenticated Claude Code CLI
- `expect` (included with macOS)

## Build and run

```sh
git clone https://github.com/scottdflorida/claude-usage-micro.git
cd claude-usage-micro
./build.sh
open "build/Claude Usage Micro.app"
```

No API key, hosted service, app-owned database, package manager, or third-party dependency is required. Every
15 minutes, the app starts a short-lived Claude Code session in safe mode, reads `/usage` through a pseudo-terminal,
and exits.
It sends no telemetry of its own.

To change the automatic refresh cadence, edit [`Sources/RefreshConfiguration.swift`](Sources/RefreshConfiguration.swift)
and rebuild.

## Development

Run the strict local checks and build with:

```sh
./test.sh
./build.sh
```

The app has no third-party dependencies and keeps terminal handling behind a small normalization boundary. The
Expect helper recognizes enough output to capture a bounded `/usage` screen; the Swift parser owns headings,
percentages, reset times, redraws, and domain validation. It accepts tested wording variations, preserves each valid
limit independently, and fails closed when a response cannot be interpreted safely.

Provider churn is intentionally localized: PTY interaction lives in `Scripts/claude-usage.exp`, transcript aliases
and validation live in `UsageTranscriptParser`, and process ownership lives in `ClaudeUsageClient`. A transient
helper, timeout, or schema failure keeps an unexpired report visible as explicitly stale. A missing Claude executable
or bundled helper clears the reading.

For local integrations, run the built executable with `--snapshot`. It prints one stable, line-oriented group per
readable limit and exits nonzero with a compact diagnostic when usage cannot be read.

## Troubleshooting

- **"Claude Code is not installed"**: the app checks `~/.local/bin`, `~/.claude/local`, the Homebrew locations,
  and every absolute `PATH` entry. If `claude` lives under a version manager, symlink it with
  `ln -s "$(command -v claude)" ~/.local/bin/claude`, then press Refresh.
- **Claude is not signed in**: run `claude` in a terminal and authenticate. The app never handles Claude
  credentials itself.
- **The gauge shows `!`**: hover over the menu-bar item for the exact diagnostic. Run
  `"build/Claude Usage Micro.app/Contents/MacOS/ClaudeUsageMicro" --snapshot` for a direct provider check.

## Uninstall

Quit the app from its popover, then delete `build/Claude Usage Micro.app` or wherever you copied it. To remove the
saved gauge choice and the private usage workspace, run:

```sh
defaults delete com.scottflorida.claudeusagemicro
rm -rf ~/Library/Application\ Support/com.scottflorida.claudeusagemicro
```

## Privacy and security

The app has no networking or telemetry code and never collects or persists Claude credentials. Authentication stays
with the local Claude Code CLI, which may communicate with Anthropic according to its own configuration. The app runs
Claude in safe mode from an owner-only workspace, keeps at most 512 KiB of transcript in memory, and discards it after
parsing. A temporary owner-only file records only the child PID for cleanup. Stalled, cancelled, or overly verbose
processes are terminated and reaped under a 100-second deadline.

## License

[MIT](LICENSE)

Claude Usage Micro is an unofficial utility and is not affiliated with Anthropic.
