# Changelog

## VelaCU v0.4.2 — 2026-08-20

- Fixed an MCP lifecycle leak where VelaCU could survive as a PID 1 orphan if its tunnel/transport parent disappeared while stdin was still held open. The server now watches its original parent and exits through the normal `core.release()` cleanup path when that parent is lost, preventing stale sessions and a stuck menu-bar status icon.
- Added a regression test that keeps stdin open while the original transport parent exits, reproducing the exact orphan-process failure mode.

## VelaCU v0.4.1 — 2026-08-20

- Added standalone VelaClick v0.3.0 SkyLight click delivery.
- Removed the Cua runtime, daemon/session/socket transport, Rust build dependency, tracked overrides, and Cua packaging files.
- Added the eighth MCP tool, `velacu_scroll(direction, amount=3, x=5.0, y=5.0)`, with native SkyLight scrolling and post-scroll capture.
- Preserved the System Settings RemoteView compatibility behavior.
- Included the verified physical-click flicker root fix, stationary minimize fade, responsive idle hover behavior, and faster contrast adaptation.
- Validated the native path with System Settings, Safari, and Chromium.
- Documented the cleanup rule: close apps/windows opened only for the task, preserve pre-existing user work windows, then call `velacu_release`.
