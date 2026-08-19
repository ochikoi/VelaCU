#!/usr/bin/env python3
"""Window-movement test. AppleScript is used only as external test setup to move the window."""
from __future__ import annotations

import base64
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SERVER = ROOT / "velacu_mcp.py"
RUNTIME = ROOT / "runtime"


def send(proc: subprocess.Popen[str], request: dict) -> dict:
    assert proc.stdin is not None and proc.stdout is not None
    proc.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
    proc.stdin.flush()
    line = proc.stdout.readline()
    if not line:
        raise RuntimeError(proc.stderr.read() if proc.stderr else "VelaCU MCP closed")
    return json.loads(line)


def call(proc: subprocess.Popen[str], req_id: int, name: str, args: dict) -> dict:
    result = send(proc, {"jsonrpc": "2.0", "id": req_id, "method": "tools/call", "params": {"name": name, "arguments": args}})["result"]
    if result.get("isError"):
        raise RuntimeError(result["content"][0]["text"])
    return result


def text(result: dict) -> str:
    return next(item["text"] for item in result["content"] if item["type"] == "text")


def save(result: dict, name: str) -> str:
    image = next(item for item in result["content"] if item["type"] == "image")
    path = RUNTIME / name
    path.write_bytes(base64.b64decode(image["data"]))
    return str(path)


def main() -> int:
    subprocess.run(["open", "-a", "System Settings"], check=True)
    time.sleep(1.0)
    proc = subprocess.Popen([sys.executable, str(SERVER)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    try:
        send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "velacu-window-move", "version": "1"}}})
        binding = json.loads(text(call(proc, 2, "velacu_bind", {"query": "系统设置"})))
        window_id = binding["window_id"]
        before_list = json.loads(text(call(proc, 3, "velacu_list", {"limit": 50})))
        before = next(item for item in before_list if item["window_id"] == window_id)
        before_image = save(call(proc, 4, "velacu_capture", {}), "velacu_move_before.png")

        current_xy = (int(before["bounds"][0]), int(before["bounds"][1]))
        target_xy = (160, 80) if current_xy == (260, 120) else (260, 120)
        script = f'tell application "System Events" to tell process "System Settings" to set position of window 1 to {{{target_xy[0]}, {target_xy[1]}}}'
        subprocess.run(["osascript", "-e", script], check=True, capture_output=True, text=True)
        time.sleep(0.7)

        after_list = json.loads(text(call(proc, 5, "velacu_list", {"limit": 50})))
        after = next(item for item in after_list if item["window_id"] == window_id)
        if before["window_id"] != after["window_id"] or (before["bounds"][0], before["bounds"][1]) == (after["bounds"][0], after["bounds"][1]):
            raise AssertionError({"before": before, "after": after})
        click = json.loads(text(call(proc, 6, "velacu_click", {"x": 0.6, "y": 4.1})))
        after_image = save(call(proc, 7, "velacu_capture", {}), "velacu_move_after.png")
        released = json.loads(text(call(proc, 8, "velacu_release", {})))
        print(json.dumps({"window_id": window_id, "before": before, "after": after, "before_image": before_image, "click": click["click"], "after_image": after_image, "release": released}, ensure_ascii=False, indent=2))
        return 0
    finally:
        if proc.poll() is None:
            proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    raise SystemExit(main())
