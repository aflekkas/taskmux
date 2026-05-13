# Contributing to Taskmux

Taskmux is currently a source-build fork. There is no hosted CI, release
automation, Homebrew publishing, updater publishing, or checked-in test suite.

## Prerequisites

- macOS 14+
- Xcode 15+
- Zig: `brew install zig`

## Setup

```bash
git submodule update --init --recursive
./scripts/setup.sh
```

## Build

Use a tagged debug build so multiple local builds do not fight over the same
socket or app bundle:

```bash
./scripts/reload.sh --tag my-change
```

The script prints the built `.app` path. It only launches the app when passed
`--launch`.

For a compile-only check:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination "platform=macOS" -derivedDataPath /tmp/cmux-my-change build
```

## Ghostty Submodule

The `ghostty` submodule is still the terminal core dependency. Before changing
it, read `docs/ghostty-fork.md` and keep the parent repo pinned to a reachable
submodule commit.
