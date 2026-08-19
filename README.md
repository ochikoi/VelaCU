# VelaCU

VelaCU is a small macOS Computer Use tool I originally made for my own use.

I wanted a simple path for an AI agent to look at one app window, choose a position, and interact with it in the background without taking over my physical mouse. After using it for a while, it felt useful enough to clean up and share.

It is intentionally small. VelaCU does not try to understand the UI for the model: the model sees the screenshot, and VelaCU performs the action.

## What it does

VelaCU exposes seven MCP tools:

```text
velacu_list
velacu_bind
velacu_capture
velacu_click
velacu_key
velacu_type
velacu_release
```

A typical visual loop is:

```text
list -> bind -> capture -> click -> inspect returned screenshot -> repeat -> release
```

`velacu_capture` captures only the bound macOS window at a fixed 640px model width and adds a visible window-local ruler from `0.0` to `10.0`.

- origin: top-left
- x increases to the right
- y increases downward
- click coordinates use one decimal place
- window movement does not change the model-facing coordinate system

`velacu_click` converts the normalized position using the target window's current bounds and returns a post-click screenshot in the same MCP call. Normal app windows use the background pixel-click route. Some cross-process macOS System Settings panes use a native compatibility fallback; VelaCU restores the previous app and cursor position immediately afterward.

Keyboard input is handled separately by VelaCU's native macOS helper and supports normal shortcuts plus Unicode text.

## A few deliberate choices

VelaCU keeps the control path narrow:

- window-scoped visual capture
- one normalized `0..10` coordinate space
- fixed 640px model capture
- no DOM targeting
- no Accessibility/AX element targeting
- background clicks do not take over the physical cursor; the System Settings compatibility fallback restores it immediately
- a small visible agent cursor for feedback
- independent runtime sessions for multiple MCP clients

When an app is being controlled, a small menu-bar indicator shows that app's icon with a cursor badge. It disappears when no VelaCU session is active.

## Install

### Release archive

Once a release archive is available, unpack it and run:

```bash
./install.sh --target codex
```

The installer puts VelaCU under `~/.local/share/velacu`, creates `~/.local/bin/velacu`, and configures the `velacu` MCP entry for Codex. Existing Codex configuration is backed up before the VelaCU entry is changed.

Then check the installation:

```bash
velacu doctor
```

macOS may ask for Screen Recording or input-event permission the first time. Grant the requested permission to the terminal/agent host and run `velacu doctor` again.

### Source checkout

The same command works from a source checkout:

```bash
./install.sh --target codex
```

If the checkout does not contain prebuilt macOS binaries, the installer builds the native helper and the modified Cua driver locally. That path requires Xcode Command Line Tools and Rust/cargo.

To install without touching any agent configuration:

```bash
./install.sh --target none
```

Then configure later:

```bash
velacu setup codex
```

For another MCP client:

```bash
velacu setup generic
```

or see [`generic-mcp.example.json`](generic-mcp.example.json).

## Codex

The recommended setup is simply:

```bash
velacu setup codex
```

For reference, the manual configuration is shown in [`codex-mcp.example.toml`](codex-mcp.example.toml).

VelaCU's MCP descriptions contain the visual coordinate rules, so a fresh agent does not need a separate coordinate prompt before using the tool.

## Build manually

```bash
python3 -m pip install -r requirements.txt
./build.sh
```

To force a clean rebuild of the modified Cua driver from the pinned upstream source:

```bash
VELACU_REBUILD_CUA=1 ./build.sh
```

The first Rust build can take a few minutes.

## Project layout

```text
velacu_mcp.py       MCP surface
velacu_core.py      binding, capture, coordinate conversion, driver bridge
native/             macOS helper and menu-bar status app
status_publisher.py lightweight lifecycle/status bridge
scripts/            driver build and release packaging helpers
third_party/        Cua-derived driver overrides and license notice
fixtures/           small deterministic test pages
```

## Cua

The final background mouse-event delivery uses a small modified part of the open-source [Cua](https://github.com/trycua/cua) driver. Cua is MIT licensed.

VelaCU keeps a narrow driver surface for window-local XY background clicks and the display-only agent cursor. The VelaCU window binding, capture/rulers, normalized coordinate protocol, MCP surface, native keyboard path, session handling, and menu-bar status UI are implemented in this project.

The exact third-party attribution and pinned source revision are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md), with the upstream MIT text preserved in [`third_party/CUA_LICENSE.md`](third_party/CUA_LICENSE.md).

## Current scope

VelaCU currently targets macOS. The current release preparation has been tested on Apple Silicon; other Mac configurations still need broader testing.

The project is intentionally not a full automation framework. Features are added only when they are useful to the basic visual-control loop.

## License

VelaCU is released under the MIT License. See [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
