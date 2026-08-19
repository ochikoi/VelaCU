# Third-party notices

VelaCU is primarily its own macOS window capture, visual ruler, MCP, keyboard, session, and status-bar implementation.

## Cua driver component

The final background pixel-click delivery uses a small modified portion of the open-source Cua driver project:

- Project: `trycua/cua`
- Upstream repository: `https://github.com/trycua/cua`
- Pinned source commit used for the current VelaCU driver build: `2fe1c3250cc84574f376aa314a077a33ef48d1dd`
- Upstream license: MIT
- Upstream copyright: Copyright (c) 2025 Cua AI, Inc.

VelaCU keeps only a narrow macOS driver surface for window-local XY background clicks and the display-only agent cursor. The modified source overlays used by VelaCU are stored under `third_party/cua-driver-overrides/`.

The complete upstream MIT license text is preserved in [`third_party/CUA_LICENSE.md`](third_party/CUA_LICENSE.md).

VelaCU does not include Cua's optional OmniParser/Ultralytics components.
