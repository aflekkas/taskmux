# Taskmux

Taskmux is a fork of [cmux](https://github.com/manaflow-ai/cmux) focused on
task-backed development environments.

The direction is:

```text
Notion task -> branch -> git worktree -> Taskmux workspace -> agent sessions -> PR/status
```

The codebase still contains many upstream `cmux` names in schemes, bundle IDs,
paths, sockets, and source symbols. Keep those intact until there is a deliberate
rename and distribution plan.

## Local Setup

Prerequisites:

- macOS 14+
- Xcode 15+
- Zig, installed with `brew install zig`

Initialize submodules and prepare GhosttyKit:

```bash
./scripts/setup.sh
```

Build a tagged debug app:

```bash
./scripts/reload.sh --tag taskmux-dev
```

The reload script prints the built `.app` path. It does not launch the app unless
you pass `--launch`.

## Repository Shape

Taskmux is intentionally lightweight for now:

- No GitHub Actions workflows.
- No CircleCI, Greptile, CodeRabbit, Claude Code action, or hosted review bots.
- No checked-in unit, UI, Python socket, or E2E test suites.
- No Homebrew publishing submodule.
- No inherited cmux release or nightly automation.

Local builds are the validation path while the fork direction is being explored.

## Product Direction

Taskmux should make a task the main unit of work. A task should be able to link
to Notion, own or discover a git branch, own or discover a git worktree, and open
a workspace with the relevant terminals, browser panes, and agent sessions.

Prefer work that strengthens task, branch, worktree, and agent workflows over
generic terminal polish.
