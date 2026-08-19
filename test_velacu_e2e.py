#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SERVER = ROOT / "velacu_mcp.py"
OUT = ROOT / "runtime" / "e2e_after.png"


def send(proc: subprocess.Popen[str], request: dict) -> dict:
    assert proc.stdin is not None and proc.stdout is not None
    proc.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
    proc.stdin.flush()
    line = proc.stdout.readline()
    if not line:
        raise RuntimeError(proc.stderr.read() if proc.stderr else "MCP server closed")
    return json.loads(line)


def call(proc: subprocess.Popen[str], req_id: int, name: str, arguments: dict) -> dict:
    r = send(proc, {
        "jsonrpc": "2.0",
        "id": req_id,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    })
    result = r["result"]
    if result.get("isError"):
        raise RuntimeError(result["content"][0]["text"])
    return result


def main() -> int:
    # Defaults target Calculator's 9 key in the current scientific layout.
    query = sys.argv[1] if len(sys.argv) > 1 else "计算器"
    x = float(sys.argv[2]) if len(sys.argv) > 2 else 8.45
    y = float(sys.argv[3]) if len(sys.argv) > 3 else 5.15

    proc = subprocess.Popen(
        [sys.executable, str(SERVER)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    try:
        send(proc, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "velacu-e2e", "version": "0.2"}},
        })
        bind = call(proc, 2, "velacu_bind", {"query": query})
        print("bind:", bind["content"][0]["text"])

        velacu_click = call(proc, 3, "velacu_click", {"x": x, "y": y})
        print("velacu_click:", velacu_click["content"][0]["text"])

        velacu_capture = call(proc, 4, "velacu_capture", {})
        image = next(item for item in velacu_capture["content"] if item["type"] == "image")
        OUT.write_bytes(base64.b64decode(image["data"]))
        print("velacu_capture:", OUT, OUT.stat().st_size, "bytes")

        velacu_released = call(proc, 5, "velacu_release", {})
        print("velacu_release:", velacu_released["content"][0]["text"])
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    raise SystemExit(main())
