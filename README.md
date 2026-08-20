# VelaCU

VelaCU is a small macOS visual Computer Use MCP server. It gives an MCP-capable agent a screenshot of one window, a visible 0..10 ruler, and native keyboard/pointer controls without taking over the user's physical mouse.

VelaCU can be used with WebGPT, Codex, and other MCP-capable agents.

Release: **VelaCU v0.4.2**
Build: **native-20260820-05**
Click backend: **VelaClick v0.3.0 SkyLight**

## Eight MCP tools

```text
velacu_list(limit=20)
velacu_bind(query | window_id)
velacu_capture()
velacu_click(x, y, button="left", count=1)
velacu_scroll(direction, amount=3, x=5.0, y=5.0)
velacu_key(key)
velacu_type(text)
velacu_release()
```

The usual visual loop is:

```text
list -> bind -> capture -> click/scroll/key/type -> inspect the returned result -> repeat
task cleanup -> release
```

`velacu_capture` and the post-action captures use a fixed 640px model width and draw a window-local ruler. The origin is the top-left; x increases right and y increases down. Click and targeted-scroll coordinates are read directly from the visible 0..10 ruler and use one decimal place. Agents should never convert them to pixels.

## VelaClick architecture

Click delivery is a standalone, stateless native helper:

```text
MCP client
   -> VelaCU MCP
      -> VelaCU core
         -> VelaClick (one process per click, CGEvent + SkyLight)
         -> VelaCUHelper (capture, keyboard, targeted scroll)
         -> VelaPointer (visual-only cursor)
```

VelaClick receives the target pid, window id, and resolved screen/local coordinates, then exits. VelaCU no longer requires or runs a Cua daemon, Cua session, Unix socket, or Rust/Cua build. There is no AX/DOM target lookup and the real mouse cursor is not moved.

`velacu_scroll` sends native SkyLight/CGEvent wheel input at the requested normalized point and returns a post-scroll screenshot. It supports `up`, `down`, `left`, and `right`, so nested scroll regions can be targeted by their visible position.

System Settings RemoteView panes retain the verified compatibility path: for that specific cross-process topology VelaCU uses a short foreground HID fallback and restores the prior application and physical cursor position. It remains pixel-only and does not use AX or DOM lookup.

The visual pointer is independent of event delivery. Recent fixes include the physical-click flicker root fix, stationary fade while minimizing, short idle hover animation without an apparent long freeze, and faster contrast adaptation. These are visual effects only and do not debounce or patch click delivery.

## Install

On macOS with Python 3.9+:

```bash
./install.sh --target codex
```

To install without changing an agent configuration:

```bash
./install.sh --target none
velacu setup codex
```

The installer creates a local VelaCU installation, a `velacu` launcher, and a timestamped backup before changing the Codex MCP configuration. Run:

```bash
velacu doctor
```

A release archive normally includes native binaries. A source checkout builds the native helper, VelaClick, VelaPointer, and status app with Xcode Command Line Tools. Source installation requires Python/Pillow and Swift; Rust and cargo are not required.

For another MCP-capable client, use `generic-mcp.example.json` or:

```bash
velacu setup generic
```

## Manual build and tests

```bash
python3 -m pip install -r requirements.txt
./build.sh
python3 -m py_compile velacu_core.py velacu_mcp.py velacu_cli.py status_publisher.py
python3 -m unittest +  test_velacu_mcp.py +  test_parallel_isolation.py +  test_velacu_keyboard.py +  test_velacu_e2e.py +  test_velacu_window_move.py +  test_zero_prompt_contract.py
```

The e2e and window-movement programs need a live macOS app/window and the relevant macOS permissions. The focused unit and contract tests do not need a live target window.

## Task cleanup rule

When an agent finishes its control task, it must close applications or windows opened only for that task, preserve user work windows that existed before the task, and then call `velacu_release`. `velacu_release` clears VelaCU's binding and visual pointer state; it does not close pre-existing user work.

## Project layout

```text
velacu_mcp.py       MCP tool surface
velacu_core.py      binding, capture, coordinate conversion, native bridges
velacu_cli.py       installer/doctor and agent setup commands
native/             VelaClick, VelaPointer, helper, and status app sources
resources/          public pointer source asset
scripts/            source/release packaging workflow
fixtures/           deterministic test pages
```

## License

VelaCU is released under the MIT License. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
