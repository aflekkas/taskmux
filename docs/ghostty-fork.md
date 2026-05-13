# Ghostty Submodule Notes

Taskmux uses the pinned `ghostty` submodule for terminal rendering. Keep Ghostty
changes local and explicit:

1. Edit the `ghostty` submodule only when the app-layer bridge cannot solve the
   problem.
2. Build `GhosttyKit.xcframework` from the local submodule with
   `./scripts/ensure-ghosttykit.sh` or `./scripts/setup.sh`.
3. Do not fetch prebuilt GhosttyKit artifacts from upstream releases.
4. If the submodule pointer changes, verify the submodule commit exists on the
   intended remote before updating the parent repo pointer.

The bridge header at `ghostty.h` must keep including
`ghostty/include/ghostty.h`; `scripts/ensure-ghosttykit.sh` validates this before
building.
