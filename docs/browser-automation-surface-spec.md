# Browser Automation Surface Spec

This document tracks the browser automation surface that remains in Taskmux
after stripping removed integration tooling. Browser automation is still useful
for local workspaces because a browser surface is one of the core openable
surface types alongside terminals, markdown, and file previews.

## Concepts

1. `window`: native macOS window.
2. `workspace`: sidebar entry within a window.
3. `pane`: split region inside a workspace.
4. `surface`: tab within a pane. A surface may be a terminal, browser,
   markdown, or file preview.
5. `panel`: internal implementation term. CLI/API docs should prefer
   `surface`; keep `--panel` only as a compatibility alias while it exists.

## Identify

`system.identify` is the canonical "where am I?" call for automation clients.

Required response fields:

1. `focused.window_id`
2. `focused.workspace_id`
3. `focused.pane_id`
4. `focused.surface_id`
5. `caller` validation result when caller context is supplied

Recommended browser fields:

1. `focused.surface_type`
2. `focused.browser.url`
3. `focused.browser.title`
4. `focused.browser.loading`

## Target API

Core methods:

1. `system.ping`
2. `system.capabilities`
3. `system.identify`
4. `window.list|current|focus|create|close`
5. `workspace.list|create|select|current|close|move_to_window|reorder`
6. `pane.list|focus|surfaces|create`
7. `surface.list|focus|split|create|close|drag_to_split|refresh|health|send_text|send_key|move|reorder`
8. `browser.open_split|navigate|back|forward|reload|url.get|focus_webview|is_webview_focused`

Browser interaction methods:

1. `browser.snapshot`
2. `browser.eval`
3. `browser.wait`
4. `browser.click`
5. `browser.dblclick`
6. `browser.type`
7. `browser.fill`
8. `browser.press|keydown|keyup`
9. `browser.hover|focus`
10. `browser.check|uncheck`
11. `browser.select`
12. `browser.scroll|scroll_into_view`
13. `browser.get.*` (`url|title|text|html|value|attr|count|box|styles`)
14. `browser.is.*` (`visible|enabled|checked`)
15. `browser.screenshot`
16. `browser.find.*` (`role|text|label|placeholder|alt|title|testid|nth|first|last`)
17. `browser.frame.*`
18. `browser.dialog.*`
19. `browser.download.*`
20. `browser.tab.*` compatibility aliases mapped to browser surfaces
21. `browser.console.*`
22. `browser.errors.*`
23. `browser.state.*`

Optional browser methods should return explicit `not_supported` errors when a
WKWebView-backed browser surface cannot implement them correctly.

## CLI Shape

Primary form:

```bash
cmux browser --surface <surface-id> <browser-command...>
```

Shorthand:

```bash
cmux browser <surface-id> <browser-command...>
```

Discovery:

```bash
cmux identify
cmux capabilities
cmux browser identify --surface <surface-id>
```

## Move and Reorder Invariants

Required capabilities:

1. Reorder surfaces within a pane.
2. Move surfaces between panes in the same workspace.
3. Move surfaces across workspaces.
4. Move surfaces across windows.
5. Reorder workspaces within a window.

Methods:

1. `surface.move` with `surface_id` plus destination and placement.
2. `surface.reorder` with `surface_id` plus sibling anchor.
3. `workspace.reorder` with `workspace_id` plus sibling anchor.

Hard invariant: `surface_id` must remain unchanged after all move/reorder
operations.

## Test Design Rules

1. Prefer deterministic local fixtures, embedded HTML, or local HTTP servers.
2. Every command gets at least one positive and one negative test when the test
   suite is present.
3. Every handle-accepting API gets tests for UUID targets and compatibility
   refs.
4. Every move/reorder test asserts `surface_id` stability before and after the
   operation.
5. Browser tests should verify behavior from both focused and unfocused webview
   states where practical.

## Removed Scope

Do not document browser automation as an integration bridge. The stripped
Taskmux direction keeps browser surfaces and local automation, but removes the
historical integration surfaces.
