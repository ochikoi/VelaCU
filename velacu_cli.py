#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Optional, Tuple

from velacu_core import VELACU_BUILD, VELACU_VERSION

ROOT = Path(__file__).resolve().parent
HELPER = ROOT / "bin" / "VelaCUHelper"
VELACLICK = ROOT / "bin" / "VelaClick"
POINTER = ROOT / "bin" / "VelaPointer"
STATUS_EXEC = ROOT / "bin" / "VelaCU Status.app" / "Contents" / "MacOS" / "VelaCUStatus"
MCP = ROOT / "velacu_mcp.py"


def find_codex() -> Optional[Path]:
    found = shutil.which("codex")
    if found:
        return Path(found)
    candidates = [
        Path("/Applications/ChatGPT.app/Contents/Resources/codex"),
        Path.home() / "Applications/ChatGPT.app/Contents/Resources/codex",
    ]
    return next((p for p in candidates if p.is_file() and os.access(p, os.X_OK)), None)


def backup_codex_config() -> Optional[Path]:
    config = Path.home() / ".codex" / "config.toml"
    if not config.exists():
        return None
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = config.with_name(f"config.toml.velacu-backup-{stamp}")
    shutil.copy2(config, backup)
    return backup


def setup_codex(dry_run: bool = False) -> int:
    codex = find_codex()
    if codex is None:
        print("Codex CLI was not found. Install/open the ChatGPT/Codex app first.", file=sys.stderr)
        return 2
    command = [str(codex), "mcp", "add", "velacu", "--", sys.executable, str(MCP)]
    if dry_run:
        print("Would configure Codex with:")
        print(" ".join(command))
        return 0
    backup = backup_codex_config()
    subprocess.run([str(codex), "mcp", "remove", "velacu"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        print(result.stderr.strip() or result.stdout.strip() or "codex mcp add failed", file=sys.stderr)
        if backup:
            shutil.copy2(backup, Path.home() / ".codex" / "config.toml")
            print(f"Restored Codex config from: {backup}", file=sys.stderr)
        return result.returncode or 2
    verify = subprocess.run([str(codex), "mcp", "get", "velacu"], text=True, capture_output=True, check=False)
    if verify.returncode != 0:
        print("VelaCU was added but Codex could not read the entry back.", file=sys.stderr)
        if backup:
            shutil.copy2(backup, Path.home() / ".codex" / "config.toml")
            print(f"Restored Codex config from: {backup}", file=sys.stderr)
        return 2
    print("Codex: VelaCU MCP configured.")
    if backup:
        print(f"Config backup: {backup}")
    print("Restart Codex if it was already running.")
    return 0


def generic_config() -> dict:
    return {
        "mcpServers": {
            "velacu": {
                "command": sys.executable,
                "args": [str(MCP)],
                "cwd": str(ROOT),
            }
        }
    }


def doctor() -> int:
    # Last tuple field says whether a failed check is fatal. macOS permission
    # prompts are expected on first install, so they are reported as warnings.
    checks: List[Tuple[str, bool, str, bool]] = []
    checks.append(("macOS", sys.platform == "darwin", sys.platform, True))
    checks.append(("Python", sys.version_info >= (3, 9), sys.version.split()[0], True))
    try:
        import PIL  # type: ignore
        checks.append(("Pillow", True, getattr(PIL, "__version__", "installed"), True))
    except Exception as exc:
        checks.append(("Pillow", False, str(exc), True))
    checks.append(("VelaCUHelper", HELPER.is_file() and os.access(HELPER, os.X_OK), str(HELPER), True))
    checks.append(("VelaClick", VELACLICK.is_file() and os.access(VELACLICK, os.X_OK), str(VELACLICK), True))
    checks.append(("VelaPointer", POINTER.is_file() and os.access(POINTER, os.X_OK), str(POINTER), True))
    checks.append(("Status app", STATUS_EXEC.is_file() and os.access(STATUS_EXEC, os.X_OK), str(STATUS_EXEC), True))
    checks.append(("screencapture", Path("/usr/sbin/screencapture").exists(), "/usr/sbin/screencapture", True))

    if HELPER.is_file() and os.access(HELPER, os.X_OK):
        try:
            probe = subprocess.run([str(HELPER), "permissions"], text=True, capture_output=True, timeout=5, check=False)
            payload = json.loads(probe.stdout) if probe.returncode == 0 else {}
            post_ok = bool(payload.get("postEventAccess"))
            checks.append(("input event permission", post_ok, "granted" if post_ok else "grant when macOS prompts", False))
        except Exception as exc:
            checks.append(("input event permission", False, str(exc), False))

    width = max(len(name) for name, _, _, _ in checks)
    print(f"VelaCU {VELACU_VERSION} ({VELACU_BUILD})")
    fatal_failed = False
    permission_warning = False
    for name, ok, detail, fatal in checks:
        fatal_failed |= fatal and not ok
        permission_warning |= (not fatal) and not ok
        marker = "✓" if ok else ("✗" if fatal else "!")
        print(f"{marker} {name:<{width}}  {detail}")
    if fatal_failed:
        return 1
    if permission_warning:
        print("\nInstall is complete. Grant the requested macOS permission, then rerun `velacu doctor`.")
        return 0
    print("\nReady.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="velacu", description="Small macOS visual Computer Use runtime")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("doctor", help="Check the local VelaCU installation")
    sub.add_parser("version", help="Print VelaCU version")
    setup = sub.add_parser("setup", help="Configure an agent/client")
    setup.add_argument("target", choices=["codex", "generic"])
    setup.add_argument("--dry-run", action="store_true", help="Show the Codex configuration command without changing files")
    sub.add_parser("mcp", help="Run the VelaCU stdio MCP server")

    args = parser.parse_args()
    if args.command == "doctor":
        return doctor()
    if args.command == "version":
        print(f"{VELACU_VERSION} {VELACU_BUILD}")
        return 0
    if args.command == "setup":
        if args.target == "codex":
            return setup_codex(dry_run=bool(args.dry_run))
        print(json.dumps(generic_config(), ensure_ascii=False, indent=2))
        return 0
    if args.command == "mcp":
        os.execv(sys.executable, [sys.executable, str(MCP)])
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
