# Taskmux Events

Taskmux exposes a reconnectable event stream for local tools that need to
observe window, workspace, pane, surface, browser, and config activity.

The same events are appended to `~/.cmuxterm/events.jsonl` as newline-delimited
JSON. The live stream is delivered over the existing socket. Clients call the v2
method `events.stream`, then keep reading newline-delimited JSON frames from the
same connection.

## Quick Start

```bash
cmux events --cursor-file ~/.cache/cmux/events.seq --reconnect
cmux events --category window --category workspace --category pane --category surface
```

Every event has a monotonically increasing process-local `seq` and a `boot_id`.
Persist the latest processed `seq`, then reconnect with `after_seq` or use
`cmux events --cursor-file`. If the app restarts, `boot_id` changes and the
server marks stale cursors as a resume gap.

Use the JSONL log for audit and catch-up tools. Use the socket stream for live
delivery with bounded replay.

Lifecycle events with `source: "window.lifecycle"` or
`source: "workspace.lifecycle"` are emitted from the app model, so they cover UI
actions, CLI/socket commands, shortcuts, startup creation, restore paths, and
AppKit focus/key transitions. Socket-sourced events are reserved for command
effects that do not have an authoritative model lifecycle event.

## Stream Request

Send one JSON request line to the socket:

```json
{"id":"client-1","method":"events.stream","params":{"after_seq":123,"categories":["workspace","surface"]}}
```

Parameters:

| Param | Type | Meaning |
| --- | --- | --- |
| `after_seq` | integer | Replay retained events whose `seq` is greater than this value. |
| `after` | integer | Alias for `after_seq`. |
| `names` | string array | Optional event-name filter. |
| `name` | string or array | Alias for `names`. |
| `categories` | string array | Optional category filter. |
| `category` | string or array | Alias for `categories`. |
| `include_heartbeats` | boolean | Defaults to `true`. Sends heartbeat frames when no event arrives. |

The request line takes over the socket connection. Do not send additional
commands on that connection after `events.stream`.

## Frames

The server writes one JSON object per line. The first frame is always `ack`.
After that, the stream sends retained replay events, then live events and
heartbeats.

Ack frames include the protocol version, `boot_id`, subscription id, heartbeat
interval, replay count, resume metadata, and resolved filters.

Event frames include:

| Field | Meaning |
| --- | --- |
| `seq` | Process-local sequence. Increases by one for every emitted event. |
| `boot_id` | UUID process-boot identifier for this in-memory event log. Changes when the app restarts. |
| `id` | Stable event id for the current process. Use it for dedupe. |
| `name` | Specific event name, such as `workspace.selected`. |
| `category` | Coarse subscription group. |
| `source` | Producer, such as `socket.v2` or `workspace.lifecycle`. |
| `occurred_at` | ISO-8601 timestamp with fractional seconds. |
| `workspace_id` | Workspace UUID when known. |
| `surface_id` | Surface UUID when known. |
| `pane_id` | Pane UUID when known. |
| `window_id` | Window UUID when known. |
| `payload` | Event-specific JSON object. |

Heartbeat frames have no `seq`. They keep the connection observable and tell
clients the server's latest sequence.

## Resume Contract

The intended client loop is:

1. Connect to the socket and authenticate if required.
2. Send `events.stream` with the last fully processed `seq`.
3. Read `ack`.
4. If `ack.resume.gap` is true, refresh state through snapshot commands.
5. Process replayed events, then live events.
6. Persist each event's `seq` only after your side effect succeeds.
7. Reconnect with the latest persisted `seq` if the socket closes.

The retained replay buffer is in memory and bounded to 4,096 events. Individual
event frames are capped to 16 KiB after JSON encoding; oversized payloads are
replaced with a small payload that sets `payload_truncated: true`.

Each live subscriber also has a bounded pending queue of 1,024 events. If a
client stops reading and falls behind that queue, the app closes that
subscription with a `slow_consumer` error. The client should reconnect with the
last `seq` it successfully processed.

## CLI

`cmux events` prints the stream as newline-delimited JSON.

Options:

| Option | Meaning |
| --- | --- |
| `--after <seq>` | Start after a sequence number. |
| `--after-seq <seq>` | Alias for `--after`. |
| `--cursor-file <path>` | Read the starting sequence from a file and update it after each event. |
| `--name <event>` | Filter by event name. Repeatable. |
| `--category <name>` | Filter by category. Repeatable. |
| `--reconnect` | Reconnect forever and resume from the last received event. |
| `--limit <n>` | Exit after printing `n` event frames. |
| `--no-ack` | Hide the initial ack frame. |
| `--no-heartbeat` | Hide heartbeat frames. |

## Event Catalog

Window:

| Name | Trigger |
| --- | --- |
| `window.created` | A main window is registered in the app model. |
| `window.focused` | A window focus request succeeded. |
| `window.keyed` | AppKit reported a main window became the key window. |
| `window.unkeyed` | AppKit reported a main window resigned key status. |
| `window.closed` | A main window was unregistered during close. |

Workspace:

| Name | Trigger |
| --- | --- |
| `workspace.created` | Workspace model created through UI, CLI, socket, startup, or restore. |
| `workspace.selected` | Selected workspace changed in a window. |
| `workspace.closed` | Workspace closed. |
| `workspace.renamed` | Workspace renamed. |
| `workspace.reordered` | Workspace order changed. |
| `workspace.moved` | Workspace moved to another window. |
| `workspace.action` | Workspace action command completed. |

Surface and pane:

| Name | Trigger |
| --- | --- |
| `surface.created` | Terminal, browser, markdown, or file preview surface created in a pane. |
| `surface.selected` | Selected surface changed inside a pane. |
| `surface.focused` | Focused surface changed for a workspace. |
| `surface.closed` | Surface closed. |
| `surface.moved` | Surface moved to another pane, workspace, or window. |
| `surface.reordered` | Surface order changed inside a pane. |
| `surface.action` | Surface or tab action command completed. |
| `surface.input_sent` | Text was sent through the socket API. Text is redacted. |
| `surface.key_sent` | Key was sent through the socket API. |
| `pane.created` | Pane created. |
| `pane.closed` | Pane closed. |
| `pane.focused` | Focused pane changed for a workspace. |
| `pane.resized` | Pane resized. |
| `pane.swapped` | Two panes swapped. |
| `pane.broken` | Pane broken into a new workspace. |
| `pane.joined` | Pane joined into another pane. |

Browser and config:

| Name | Trigger |
| --- | --- |
| `browser.navigation` | Browser navigation command completed. |
| `browser.interaction` | Browser click, hover, scroll, key, select, or focus command completed. |
| `browser.input` | Browser type/fill command completed. Input value is redacted. |
| `config.reloaded` | Configuration reload requested through the socket API. |

## Privacy

`surface.input_sent` and `browser.input` redact local text and include only
length metadata. Consumers should treat the stream as local-sensitive data and
avoid forwarding it to third-party services without explicit user opt-in.
