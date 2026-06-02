#Llm Alarm Terminal

macOS desktop terminal that hosts Claude Code and shell sessions through a single libghostty-backed terminal view, with a future companion mobile chat app for remote interaction.

## Status

P1 in progress — see `docs/plans/p1/p1-detailed.html` for the day-by-day plan and `docs/plans/work-plan-v4.md` for the master plan.

## Quick start

```sh
# One-time setup: install Xcode and Homebrew packages, then:
brew install xcodegen zig

# Generate the Xcode project and run a debug build:
scripts/build.sh debug
```

See `docs/build-setup.md` for the full development host setup including Developer ID and notarization credentials.

## Layout

```
Sources/ClaudeAlarmTerminal/    AppKit app entry point and main delegate
Resources/                       Info.plist and entitlements
scripts/                         Build, packaging, and release scripts
docs/                            Plans, ADRs, and build documentation
vendor/                          Pinned third-party sources (added in Day 2)
```

## License

Internal project. Not published.
