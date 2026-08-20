#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SERVER = ROOT / "velacu_mcp.py"


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def main() -> int:
    read_fd, write_fd = os.pipe()
    launcher_code = r'''
import subprocess
import sys
import time

server = sys.argv[1]
read_fd = int(sys.argv[2])
child = subprocess.Popen(
    [sys.executable, server],
    stdin=read_fd,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    close_fds=True,
)
print(child.pid, flush=True)
# Keep the real parent alive long enough for the child to record our PID and
# start its watchdog, then disappear without closing the grandparent-held
# write side of the stdin pipe.
time.sleep(1.0)
'''
    launcher = subprocess.Popen(
        [sys.executable, "-c", launcher_code, str(SERVER), str(read_fd)],
        pass_fds=(read_fd,),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    os.close(read_fd)
    try:
        assert launcher.stdout is not None
        line = launcher.stdout.readline().strip()
        if not line:
            err = launcher.stderr.read() if launcher.stderr else ""
            raise RuntimeError(f"launcher did not report child pid: {err}")
        child_pid = int(line)
        if not pid_alive(child_pid):
            raise AssertionError("VelaCU child exited before its transport parent disappeared")

        launcher.wait(timeout=3.0)
        deadline = time.monotonic() + 4.0
        while time.monotonic() < deadline and pid_alive(child_pid):
            time.sleep(0.1)
        if pid_alive(child_pid):
            raise AssertionError(
                f"VelaCU child {child_pid} survived transport-parent death while stdin remained open"
            )
        print("parent lifecycle: PASS")
        return 0
    finally:
        os.close(write_fd)
        if launcher.poll() is None:
            launcher.kill()
            launcher.wait(timeout=1.0)


if __name__ == "__main__":
    raise SystemExit(main())
