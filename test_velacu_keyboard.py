#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SERVER = ROOT / "velacu_mcp.py"
HELPER = ROOT / "bin" / "VelaCUHelper"
RUNTIME = ROOT / "runtime"
FILE_URL = (ROOT / "fixtures" / "zero_prompt.html").resolve().as_uri()


def send(proc: subprocess.Popen[str], request: dict) -> dict:
    assert proc.stdin is not None and proc.stdout is not None
    proc.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
    proc.stdin.flush()
    line = proc.stdout.readline()
    if not line:
        raise RuntimeError(proc.stderr.read() if proc.stderr else "VelaCU MCP closed")
    return json.loads(line)


def call(proc: subprocess.Popen[str], req_id: int, name: str, arguments: dict) -> dict:
    result = send(proc, {
        "jsonrpc": "2.0",
        "id": req_id,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    })["result"]
    if result.get("isError"):
        raise RuntimeError(f"{name}: {result['content'][0]['text']}")
    return result


def text(result: dict) -> str:
    return next(item["text"] for item in result["content"] if item["type"] == "text")


def save_image(result: dict, name: str) -> str:
    image = next(item for item in result["content"] if item["type"] == "image")
    path = RUNTIME / name
    path.write_bytes(base64.b64decode(image["data"]))
    return str(path)


def cursor() -> tuple[float, float]:
    value = json.loads(subprocess.check_output([str(HELPER), "cursor"], text=True))
    return float(value["x"]), float(value["y"])


def timed(proc: subprocess.Popen[str], req_id: int, name: str, arguments: dict) -> tuple[dict, float]:
    start = time.perf_counter()
    result = call(proc, req_id, name, arguments)
    return result, (time.perf_counter() - start) * 1000.0


def main() -> int:
    query = sys.argv[1] if len(sys.argv) > 1 else "VelaCU Stopwatch"
    proc = subprocess.Popen(
        [sys.executable, str(SERVER)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    req_id = 1
    key_latencies: list[float] = []
    type_latencies: list[float] = []
    try:
        init = send(proc, {
            "jsonrpc": "2.0", "id": req_id, "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "velacu-keyboard-test", "version": "1"}},
        })
        req_id += 1
        listed = call(proc, req_id, "velacu_list", {"limit": 50})
        req_id += 1
        tool_names = [tool["name"] for tool in init["result"].get("capabilities", {}).get("tools", {})] if False else None
        expected = {"velacu_list", "velacu_bind", "velacu_capture", "velacu_click", "velacu_key", "velacu_type", "velacu_release"}
        tools_response = send(proc, {"jsonrpc": "2.0", "id": req_id, "method": "tools/list", "params": {}})
        req_id += 1
        names = {tool["name"] for tool in tools_response["result"]["tools"]}
        if names != expected:
            raise AssertionError(f"unexpected tools: {sorted(names)}")

        call(proc, req_id, "velacu_release", {})
        req_id += 1
        unbound = send(proc, {"jsonrpc": "2.0", "id": req_id, "method": "tools/call", "params": {"name": "velacu_key", "arguments": {"key": "escape"}}})["result"]
        req_id += 1
        if not unbound.get("isError") or "No VelaCU window is bound" not in text(unbound):
            raise AssertionError(f"unbound key did not fail closed: {unbound}")

        binding = json.loads(text(call(proc, req_id, "velacu_bind", {"query": query})))
        req_id += 1
        before = cursor()

        def key(value: str) -> dict:
            nonlocal req_id
            result, elapsed = timed(proc, req_id, "velacu_key", {"key": value})
            req_id += 1
            key_latencies.append(elapsed)
            return json.loads(text(result))

        def type_text(value: str) -> dict:
            nonlocal req_id
            result, elapsed = timed(proc, req_id, "velacu_type", {"text": value})
            req_id += 1
            type_latencies.append(elapsed)
            return json.loads(text(result))

        key("cmd+t")
        time.sleep(0.6)
        new_tab_image = save_image(call(proc, req_id, "velacu_capture", {}), "velacu_keyboard_new_tab.png")
        req_id += 1

        searches = ["abandon", "天气", "abandon发音", "日本天气"]
        search_images = []
        search_results = []
        for index, query_text in enumerate(searches, 1):
            key("cmd+l")
            typed = type_text(query_text)
            key("return")
            time.sleep(1.8)
            image_path = save_image(call(proc, req_id, "velacu_capture", {}), f"velacu_search_{index}.png")
            req_id += 1
            search_images.append(image_path)
            search_results.append({"query": query_text, "type": typed})

        loop_start = time.perf_counter()
        for _ in range(30):
            key("cmd+t")
            key("cmd+w")
        loop_ms = (time.perf_counter() - loop_start) * 1000.0

        key("cmd+l")
        type_text(FILE_URL)
        key("return")
        time.sleep(1.2)
        call(proc, req_id, "velacu_capture", {})
        req_id += 1
        clicked = json.loads(text(call(proc, req_id, "velacu_click", {"x": 5.0, "y": 6.9})))
        req_id += 1
        type_text("velacu-mix")
        key("cmd+l")
        type_text(FILE_URL)
        key("return")
        time.sleep(1.2)
        mixed_image = save_image(call(proc, req_id, "velacu_capture", {}), "velacu_mixed_final.png")
        req_id += 1
        after = cursor()
        released = json.loads(text(call(proc, req_id, "velacu_release", {})))
        print(json.dumps({
            "server": init["result"]["serverInfo"],
            "listed_count": len(json.loads(text(listed))),
            "tools": sorted(names),
            "binding": binding,
            "unbound_key_rejected": True,
            "new_tab_image": new_tab_image,
            "searches": search_results,
            "search_images": search_images,
            "thirty_cmd_t_cmd_w": {"iterations": 30, "total_ms": loop_ms},
            "mixed_click": clicked["click"],
            "mixed_image": mixed_image,
            "cursor_before": before,
            "cursor_after": after,
            "average_key_ms": sum(key_latencies) / len(key_latencies),
            "average_type_ms": sum(type_latencies) / len(type_latencies),
            "release": released,
        }, ensure_ascii=False, indent=2))
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
