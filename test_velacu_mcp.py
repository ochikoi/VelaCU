#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SERVER = ROOT / "velacu_mcp.py"
RUNTIME = ROOT / "runtime"
RUNTIME.mkdir(exist_ok=True)


def send(proc: subprocess.Popen[str], obj: dict) -> dict:
    assert proc.stdin is not None and proc.stdout is not None
    proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
    proc.stdin.flush()
    line = proc.stdout.readline()
    if not line:
        err = proc.stderr.read() if proc.stderr else ""
        raise RuntimeError(f"server closed: {err}")
    return json.loads(line)


def main() -> int:
    query = sys.argv[1] if len(sys.argv) > 1 else "计算器"
    proc = subprocess.Popen(
        [sys.executable, str(SERVER)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    try:
        r = send(proc, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "velacu-smoke", "version": "0.1"}},
        })
        print("initialize:", r["result"]["serverInfo"])

        r = send(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        names = [t["name"] for t in r["result"]["tools"]]
        print("tools:", names)

        r = send(proc, {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {"name": "velacu_bind", "arguments": {"query": query}},
        })
        if r["result"].get("isError"):
            print("bind failed:", r["result"]["content"][0]["text"])
            return 2
        print("bind:", r["result"]["content"][0]["text"])

        r = send(proc, {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {"name": "velacu_capture", "arguments": {}},
        })
        if r["result"].get("isError"):
            print("velacu_capture failed:", r["result"]["content"][0]["text"])
            return 3
        content = r["result"]["content"]
        note = next(x["text"] for x in content if x["type"] == "text")
        image = next(x for x in content if x["type"] == "image")
        out = RUNTIME / "mcp_velacu_capture.png"
        out.write_bytes(base64.b64decode(image["data"]))
        print("velacu_capture:", note)
        print("image:", out, out.stat().st_size, "bytes")
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    raise SystemExit(main())
