#!/usr/bin/env python3
"""Asynchronous, per-session status publication for VelaCU.

This helper deliberately does not participate in click/capture/key/type.  The
core starts it only for bind, release, and target-loss transitions.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT / "runtime"
STATUS_ROOT = RUNTIME / "status"
SESSIONS = STATUS_ROOT / "sessions"
COMMANDS = STATUS_ROOT / "commands"
STATUS_APP = ROOT / "bin" / "VelaCU Status.app"
STATUS_EXECUTABLE = STATUS_APP / "Contents" / "MacOS" / "VelaCUStatus"
APP_PID_FILE = STATUS_ROOT / "status-app.pid"


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def ensure_status_app() -> None:
    """Start one background status app if it is not already alive."""
    if not STATUS_EXECUTABLE.exists():
        return
    try:
        pid = int(APP_PID_FILE.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        pid = 0
    if _pid_alive(pid):
        return
    try:
        APP_PID_FILE.unlink()
    except FileNotFoundError:
        pass
    subprocess.Popen(
        # Launch the native executable directly. This is a background
        # LSUIElement app and avoids LaunchServices rejecting an unsigned
        # development bundle with OSStatus -10825.
        [str(STATUS_EXECUTABLE)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def publish(session: str, payload: dict) -> None:
    payload = dict(payload)
    payload["session_id"] = session
    payload["updated_at"] = time.time()
    _atomic_write(SESSIONS / f"{session}.json", json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
    ensure_status_app()


def release(session: str) -> None:
    try:
        (SESSIONS / f"{session}.json").unlink()
    except FileNotFoundError:
        pass


def request_release(session: str) -> None:
    _atomic_write(COMMANDS / f"{session}.release", b"release\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p_publish = sub.add_parser("publish")
    p_publish.add_argument("--session", required=True)
    p_publish.add_argument("--payload", required=True)
    p_release = sub.add_parser("release")
    p_release.add_argument("--session", required=True)
    p_request = sub.add_parser("request-release")
    p_request.add_argument("--session", required=True)
    args = parser.parse_args()
    if args.command == "publish":
        publish(args.session, json.loads(args.payload))
    elif args.command == "release":
        release(args.session)
    else:
        request_release(args.session)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
