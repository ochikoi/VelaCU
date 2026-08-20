#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import signal
import sys
import time
from pathlib import Path
from typing import Any

from velacu_core import MODEL_CAPTURE_WIDTH, VELACU_BUILD, VELACU_VERSION, VelaCUCore, VelaCUError, list_windows

SERVER_NAME = "velacu-mcp"
SERVER_VERSION = VELACU_VERSION
PROTOCOL_VERSION = "2024-11-05"

core = VelaCUCore()
TIMING_LOG = Path(__file__).resolve().parent / "runtime" / "timing.jsonl"
_last_tool_end_ns: int | None = None


def log_tool_timing(name: str, start_ns: int, end_ns: int) -> None:
    global _last_tool_end_ns
    gap_ms = None if _last_tool_end_ns is None else (start_ns - _last_tool_end_ns) / 1_000_000.0
    record = {
        "wall_time": time.time(),
        "tool": name,
        "gap_since_previous_tool_ms": gap_ms,
        "server_duration_ms": (end_ns - start_ns) / 1_000_000.0,
    }
    TIMING_LOG.parent.mkdir(exist_ok=True)
    with TIMING_LOG.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
    _last_tool_end_ns = end_ns


TOOLS = [
    {
        "name": "velacu_list",
        "description": "List ordinary macOS application windows visible to VelaCU. This uses CoreGraphics window metadata only; it does not inspect Accessibility/AX elements.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 20}
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "velacu_bind",
        "description": "Bind VelaCU to one target window by app/title query or exact window id. The binding is persistent by CGWindow id: page/title changes do not require another bind, and re-binding the same live window is idempotent.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Case-insensitive app owner or window title substring."},
                "window_id": {"type": "integer", "description": "Exact CGWindow id."},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "velacu_capture",
        "description": "Capture only the bound window at VelaCU's fixed 640px model width and add a visible 0..10 window-local ruler. Read the ruler directly: origin is top-left, x increases right, y increases down. A target near the bottom has y near 10, not near 0. Use exactly one decimal place in velacu_click and never convert the image to pixel coordinates.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
    {
        "name": "velacu_click",
        "description": "Click the bound window through the standalone VelaClick SkyLight backend using the visible 0..10 window-local ruler, then immediately return a fixed-640px post-click screenshot. Origin is top-left; x increases right and y increases down, so lower targets have larger y values. Use one decimal place and never convert to pixels. VelaClick is stateless and uses no AX/DOM lookup, socket, daemon, or click session.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "x": {"type": "number", "minimum": 0, "maximum": 10, "description": "0..10 window-local x coordinate. Supply one decimal place (0.1 steps)."},
                "y": {"type": "number", "minimum": 0, "maximum": 10, "description": "0..10 window-local y coordinate. Supply one decimal place (0.1 steps)."},
                "button": {"type": "string", "enum": ["left"], "default": "left"},
                "count": {"type": "integer", "minimum": 1, "maximum": 2, "default": 1},
            },
            "required": ["x", "y"],
            "additionalProperties": False,
        },
    },
    {
        "name": "velacu_scroll",
        "description": "Scroll the bound window at a specific visible 0..10 window-local point using VelaCU's native SkyLight wheel path. Use x/y to target the page or a nested scroll area. The physical cursor is not moved.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "direction": {"type": "string", "enum": ["up", "down", "left", "right"]},
                "amount": {"type": "integer", "minimum": 1, "maximum": 10, "default": 3},
                "x": {"type": "number", "minimum": 0, "maximum": 10, "default": 5.0},
                "y": {"type": "number", "minimum": 0, "maximum": 10, "default": 5.0},
            },
            "required": ["direction"],
            "additionalProperties": False,
        },
    },
    {
        "name": "velacu_key",
        "description": "Press a keyboard key or shortcut using VelaCU's native system keyboard backend. Examples: cmd+t, cmd+l, return, escape, shift+tab. Do not use bash or generate OS-level keyboard commands yourself.",
        "inputSchema": {
            "type": "object",
            "properties": {"key": {"type": "string"}},
            "required": ["key"],
            "additionalProperties": False,
        },
    },
    {
        "name": "velacu_type",
        "description": "Type arbitrary Unicode text through VelaCU's native keyboard backend. Supports English, Chinese, Japanese and other Unicode text. Do not use bash, AppleScript or clipboard commands yourself.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
            "additionalProperties": False,
        },
    },
    {
        "name": "velacu_release",
        "description": "Release VelaCU's bound window and visual pointer state. Call this when the control task is finished. Before release, close applications or windows that were opened only for this task; never close the user's pre-existing work windows just for cleanup. VelaClick itself is stateless and has no daemon or click session.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
]


def text_content(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, str):
        text = value
    else:
        text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return [{"type": "text", "text": text}]


def tool_call(name: str, args: dict[str, Any]) -> dict[str, Any]:
    if name == "velacu_list":
        limit = max(1, min(int(args.get("limit", 20)), 50))
        windows = list_windows()[:limit]
        compact = [
            {
                "window_id": int(w["windowID"]),
                "pid": int(w["pid"]),
                "owner": w.get("owner", ""),
                "title": w.get("title", ""),
                "bundle_id": w.get("bundleID"),
                "bounds": [w.get("x"), w.get("y"), w.get("width"), w.get("height")],
            }
            for w in windows
        ]
        return {"content": text_content(compact), "isError": False}

    if name == "velacu_bind":
        query = args.get("query")
        window_id = args.get("window_id")
        if not query and window_id is None:
            raise VelaCUError("velacu_bind requires query or window_id")
        w = core.bind(query=query, window_id=window_id)
        result = {
            "bound": True,
            "window_id": int(w["windowID"]),
            "pid": int(w["pid"]),
            "owner": w.get("owner", ""),
            "title": w.get("title", ""),
            "click_backend": w.get("clickBackend", "velacu-native-pixel-only"),
            "bounds_points": [w.get("x"), w.get("y"), w.get("width"), w.get("height")],
            "backend_version": VELACU_VERSION,
            "backend_build": VELACU_BUILD,
        }
        return {"content": text_content(result), "isError": False}

    if name == "velacu_capture":
        image, meta = core.capture(max_width=MODEL_CAPTURE_WIDTH)
        w = meta["window"]
        note = {
            "coordinate_system": "0..10 normalized window-local; origin top-left; x right; y down",
            "bound_window": {
                "window_id": int(w["windowID"]),
                "owner": w.get("owner", ""),
                "title": w.get("title", ""),
            },
            "raw_capture_px": [meta["raw_width"], meta["raw_height"]],
            "model_content_px": [meta["content_width"], meta["content_height"]],
            "backend_version": VELACU_VERSION,
            "backend_build": VELACU_BUILD,
            "instruction": "Read the visible 0..10 ruler directly and call velacu_click(x,y). Origin is top-left; x goes right and y goes down. Targets near the bottom must have y closer to 10. Use exactly one decimal place (0.1 steps) and never convert to pixels.",
        }
        return {
            "content": [
                {"type": "text", "text": json.dumps(note, ensure_ascii=False, separators=(",", ":"))},
                {"type": "image", "data": base64.b64encode(image).decode("ascii"), "mimeType": "image/png"},
            ],
            "isError": False,
        }

    if name == "velacu_click":
        if "x" not in args or "y" not in args:
            raise VelaCUError("click requires x and y")
        click_result = core.click(
            x=float(args["x"]),
            y=float(args["y"]),
            button=str(args.get("button", "left")),
            count=int(args.get("count", 1)),
        )
        # Give the target app a brief moment to commit the click-driven UI update
        # before taking the verification frame. This avoids racing Safari's event loop
        # while keeping click + visual confirmation in one tool round-trip.
        time.sleep(0.15)
        image, meta = core.capture(max_width=MODEL_CAPTURE_WIDTH)
        w = meta["window"]
        note = {
            "click": click_result,
            "post_click_capture": {
                "coordinate_system": "0..10 normalized window-local; origin top-left; x right; y down",
                "bound_window": {
                    "window_id": int(w["windowID"]),
                    "owner": w.get("owner", ""),
                    "title": w.get("title", ""),
                },
                "raw_capture_px": [meta["raw_width"], meta["raw_height"]],
                "model_content_px": [meta["content_width"], meta["content_height"]],
                "backend_version": VELACU_VERSION,
                "backend_build": VELACU_BUILD,
            },
        }
        return {
            "content": [
                {"type": "text", "text": json.dumps(note, ensure_ascii=False, separators=(",", ":"))},
                {"type": "image", "data": base64.b64encode(image).decode("ascii"), "mimeType": "image/png"},
            ],
            "isError": False,
        }

    if name == "velacu_scroll":
        direction = args.get("direction")
        if not isinstance(direction, str):
            raise VelaCUError("scroll requires direction")
        scroll_result = core.scroll(
            direction=direction,
            amount=int(args.get("amount", 3)),
            x=float(args.get("x", 5.0)),
            y=float(args.get("y", 5.0)),
        )
        time.sleep(0.10)
        image, meta = core.capture(max_width=MODEL_CAPTURE_WIDTH)
        w = meta["window"]
        note = {
            "scroll": scroll_result,
            "post_scroll_capture": {
                "coordinate_system": "0..10 normalized window-local; origin top-left; x right; y down",
                "bound_window": {
                    "window_id": int(w["windowID"]),
                    "owner": w.get("owner", ""),
                    "title": w.get("title", ""),
                },
                "backend_version": VELACU_VERSION,
                "backend_build": VELACU_BUILD,
            },
        }
        return {
            "content": [
                {"type": "text", "text": json.dumps(note, ensure_ascii=False, separators=(",", ":"))},
                {"type": "image", "data": base64.b64encode(image).decode("ascii"), "mimeType": "image/png"},
            ],
            "isError": False,
        }

    if name == "velacu_key":
        key = args.get("key")
        if not isinstance(key, str):
            raise VelaCUError("key must be a string")
        return {"content": text_content({**core.key(key), "backend_version": VELACU_VERSION, "backend_build": VELACU_BUILD}), "isError": False}

    if name == "velacu_type":
        text = args.get("text")
        if not isinstance(text, str):
            raise VelaCUError("text must be a string")
        return {"content": text_content({**core.type_text(text), "backend_version": VELACU_VERSION, "backend_build": VELACU_BUILD}), "isError": False}

    if name == "velacu_release":
        return {"content": text_content({**core.release(), "backend_version": VELACU_VERSION, "backend_build": VELACU_BUILD}), "isError": False}

    raise VelaCUError(f"Unknown tool: {name}")


def handle(msg: dict[str, Any]) -> dict[str, Any] | None:
    method = msg.get("method")
    req_id = msg.get("id")

    if method == "initialize":
        requested = msg.get("params", {}).get("protocolVersion")
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": requested or PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": True}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                "instructions": "VelaCU is a small visual window-control tool. Typical flow: velacu_list -> velacu_bind -> velacu_capture -> velacu_click/scroll/key/type -> inspect the returned screenshot -> repeat -> cleanup -> velacu_release. Capture width is fixed at 640px. For clicks and targeted scroll, read the visible 0..10 ruler directly: origin top-left, x increases right, y increases down; use one decimal place only. When the requested control task is complete, close applications or windows opened only for that task, preserve the user's pre-existing work windows, then call velacu_release. Never calculate pixels, use AX/DOM, emit bash/osascript/System Events/clipboard input, or use an official Computer Use path.",
            },
        }

    if method == "notifications/initialized":
        return None

    if method == "ping":
        return {"jsonrpc": "2.0", "id": req_id, "result": {}}

    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}}

    if method == "tools/call":
        params = msg.get("params") or {}
        name = str(params.get("name", ""))
        args = params.get("arguments") or {}
        start_ns = time.perf_counter_ns()
        try:
            result = tool_call(name, args)
        except Exception as exc:
            result = {"content": text_content(str(exc)), "isError": True}
        finally:
            end_ns = time.perf_counter_ns()
            try:
                log_tool_timing(name, start_ns, end_ns)
            except Exception:
                pass
        return {"jsonrpc": "2.0", "id": req_id, "result": result}

    if req_id is None:
        return None

    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {"code": -32601, "message": f"Method not found: {method}"},
    }


def main() -> int:
    # MCP stdio transport: one JSON-RPC object per line.
    def shutdown(signum: int, _frame: Any) -> None:
        try:
            core.release()
        finally:
            raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
                response = handle(msg)
                if response is not None:
                    sys.stdout.write(json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n")
                    sys.stdout.flush()
                if msg.get("method") == "notifications/initialized":
                    notification = {"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}
                    sys.stdout.write(json.dumps(notification, ensure_ascii=False, separators=(",", ":")) + "\n")
                    sys.stdout.flush()
            except Exception as exc:
                sys.stderr.write(f"VelaCU MCP error: {exc}\n")
                sys.stderr.flush()
    finally:
        try:
            core.release()
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
