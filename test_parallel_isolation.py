#!/usr/bin/env python3
"""Run two independent canonical VelaCU MCP sessions in parallel."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

VELA = Path(__file__).resolve().parent


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
        raise RuntimeError(f"{name}: {result['content'][0]['text']}")
    return result


def text(result: dict) -> str:
    return next(item["text"] for item in result["content"] if item["type"] == "text")


def start(client_name: str) -> subprocess.Popen[str]:
    proc = subprocess.Popen([sys.executable, str(VELA / "velacu_mcp.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": client_name, "version": "1"}}})
    return proc


def stop(proc: subprocess.Popen[str]) -> None:
    if proc.poll() is None:
        proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()


def main() -> int:
    subprocess.run(["open", "-a", "Calculator"], check=True)
    subprocess.run(["open", "-a", "System Settings"], check=True)
    import time
    time.sleep(1.0)
    first = start("velacu-parallel-a")
    second = start("velacu-parallel-b")
    try:
        first_bind = json.loads(text(call(first, 2, "velacu_bind", {"query": "计算器"})))
        second_bind = json.loads(text(call(second, 2, "velacu_bind", {"query": "系统设置"})))
        first_capture = call(first, 3, "velacu_capture", {})
        second_capture = call(second, 3, "velacu_capture", {})
        first_click = json.loads(text(call(first, 4, "velacu_click", {"x": 5.0, "y": 0.2})))['click']
        second_click = json.loads(text(call(second, 4, "velacu_click", {"x": 5.0, "y": 0.2})))['click']
        sockets = sorted((VELA / "runtime").glob("velacu-cua-*.sock"))
        if len(sockets) != 2:
            raise AssertionError({"sockets_while_both_alive": [str(p) for p in sockets]})

        call(second, 5, "velacu_release", {})
        if not any(p.exists() for p in sockets):
            raise AssertionError("second release removed both session sockets")
        first_after_release = json.loads(text(call(first, 5, "velacu_capture", {})))
        first_socket_count = len(list((VELA / "runtime").glob("velacu-cua-*.sock")))
        call(first, 6, "velacu_release", {})
        print(json.dumps({
            "first_bind": first_bind,
            "second_bind": second_bind,
            "first_capture_image": any(item.get("type") == "image" for item in first_capture["content"]),
            "second_capture_image": any(item.get("type") == "image" for item in second_capture["content"]),
            "first_click": first_click,
            "second_click": second_click,
            "sockets_while_both_alive": [str(p) for p in sockets],
            "first_capture_after_second_release": {"window_id": first_after_release["bound_window"]["window_id"]},
            "socket_count_after_second_release": first_socket_count,
            "second_release_left_first_alive": first_socket_count == 1,
        }, ensure_ascii=False, indent=2))
        return 0
    finally:
        stop(second)
        stop(first)


if __name__ == "__main__":
    raise SystemExit(main())
