#!/usr/bin/env python3
from __future__ import annotations

import io
import atexit
import fcntl
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
HELPER = ROOT / "bin" / "VelaCUHelper"
SCREENCAPTURE = Path("/usr/sbin/screencapture")
RUNTIME = ROOT / "runtime"
RUNTIME.mkdir(exist_ok=True)
CUA_DRIVER = ROOT / "bin" / "velacu-cua-driver"
STATUS_PUBLISHER = ROOT / "status_publisher.py"
STATUS_COMMANDS = RUNTIME / "status" / "commands"
VELACU_VERSION = "0.3.0"
VELACU_BUILD = "stable-20260818-01"
MODEL_CAPTURE_WIDTH = 640


class VelaCUError(RuntimeError):
    pass


class CuaClickBridge:
    """Persistent pixel-only Cua executor on a private Unix socket.

    The binary and socket path are owned by VelaCU,
    so calls can never fall through to an installed/official Cua daemon.
    """

    def __init__(self) -> None:
        self.socket = RUNTIME / f"velacu-cua-{os.getpid()}.sock"
        self.start_lock = RUNTIME / "velacu-cua.lock"
        self.log_path = RUNTIME / f"velacu-cua-{os.getpid()}.log"
        self.daemon: subprocess.Popen[bytes] | None = None
        self._daemon_owned = False
        self._log_handle = None
        self.conn: socket.socket | None = None
        self.reader = None
        self._preflight_done = False
        atexit.register(self.close)

    def preflight(self) -> None:
        if self._preflight_done and self._socket_is_live():
            return
        if not CUA_DRIVER.exists():
            raise VelaCUError(f"Cua Driver is not installed at {CUA_DRIVER}")
        tools = subprocess.run(
            [str(CUA_DRIVER), "list-tools"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=3.0,
            check=False,
        )
        if tools.returncode != 0 or "click: Pure XY background click" not in tools.stdout:
            raise VelaCUError("VelaCU pixel-only Cua backend failed tool-surface preflight")
        self._start_daemon()
        self._preflight_done = True

    def _start_daemon(self) -> None:
        # Multiple standalone MCP server processes can overlap while an old
        # one is still draining.  Never unlink a live socket: doing so strands
        # the old daemon and starts another daemon on the same pathname, which
        # was the source of the observed Connection refused/duplicate process
        # failures.
        RUNTIME.mkdir(exist_ok=True)
        with self.start_lock.open("a+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                if self._socket_is_live():
                    self._daemon_owned = False
                    return
                self._stop_daemon()
                try:
                    self.socket.unlink()
                except FileNotFoundError:
                    pass
                env = os.environ.copy()
                env["HOME"] = str(Path.home())
                # This is already the private VelaCU child process. Skipping
                # Cua's macOS responsibility re-exec keeps serve in this
                # process group; without it the source-installed binary can
                # re-exec through LaunchServices and never create our socket.
                env["CUA_DRIVER_RS_RESPONSIBILITY_DISCLAIMED"] = "1"
                self._log_handle = self.log_path.open("ab")
                self.daemon = subprocess.Popen(
                    [str(CUA_DRIVER), "serve", "--socket", str(self.socket), "--no-permissions-gate"],
                    stdin=subprocess.DEVNULL,
                    stdout=self._log_handle,
                    stderr=self._log_handle,
                    env=env,
                    start_new_session=True,
                )
                self._daemon_owned = True
                for _ in range(100):
                    if self.daemon.poll() is not None:
                        break
                    if self._socket_is_live():
                        return
                    time.sleep(0.03)
                detail = ""
                try:
                    detail = self.log_path.read_text(encoding="utf-8", errors="replace")[-1000:]
                except OSError:
                    pass
                raise VelaCUError(
                    "VelaCU private Cua daemon failed to create a live socket"
                    + (f": {detail.strip()}" if detail.strip() else "")
                )
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _socket_is_live(self, timeout: float = 0.2) -> bool:
        if not self.socket.exists():
            return False
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.settimeout(timeout)
            probe.connect(str(self.socket))
            # Complete the daemon's read-only list request. A connect-and-close
            # probe is accepted by the kernel but makes Cua log a peer-
            # credential rejection, and it does not prove the protocol is live.
            probe.sendall(b'{"method":"list"}\n')
            return bool(probe.recv(4096))
        except OSError:
            return False
        finally:
            probe.close()

    def _close_connection(self) -> None:
        reader = self.reader
        self.reader = None
        if reader is not None:
            try:
                reader.close()
            except Exception:
                pass
        conn = self.conn
        self.conn = None
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass

    def _stop_daemon(self) -> None:
        self._close_connection()
        proc = self.daemon
        self.daemon = None
        owned = self._daemon_owned
        self._daemon_owned = False
        if owned and proc is not None:
            # `cua-driver serve` owns a supervisor plus a worker.  Popen's
            # terminate() only reaches the supervisor, leaving the worker
            # listening on the private socket after release.  The child is in
            # the new session/process group created above, so terminate the
            # whole group even if the supervisor has already exited.
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                proc.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                try:
                    proc.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    pass
        if owned:
            try:
                self.socket.unlink()
            except FileNotFoundError:
                pass
        handle = self._log_handle
        self._log_handle = None
        if handle is not None:
            try:
                handle.close()
            except OSError:
                pass

    def _connect(self, timeout: float = 3.0) -> None:
        self.preflight()
        if self.conn is not None and self.reader is not None:
            return
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(str(self.socket))
        self.conn = conn
        self.reader = conn.makefile("rb")

    def _raw_request(self, request: dict[str, Any], timeout: float = 5.0) -> dict[str, Any]:
        last_error: Exception | None = None
        for attempt in range(2):
            try:
                self._connect(timeout=timeout)
                assert self.conn is not None and self.reader is not None
                self.conn.settimeout(timeout)
                wire = json.dumps(request, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"
                self.conn.sendall(wire)
                line = self.reader.readline()
                if not line:
                    raise VelaCUError("Cua private socket closed without a response")
                response = json.loads(line.decode("utf-8"))
                if not response.get("ok"):
                    raise VelaCUError(str(response.get("error") or response))
                return response.get("result") or {}
            except Exception as exc:
                last_error = exc
                self._close_connection()
                if attempt == 0:
                    self._preflight_done = False
                    self._start_daemon()
                    self._preflight_done = True
                    continue
                break
        raise VelaCUError(f"Cua private-socket request failed: {last_error}")

    def _call(self, tool: str, payload: dict[str, Any], timeout: float = 5.0) -> dict[str, Any]:
        result = self._raw_request({"method": "call", "name": tool, "args": payload}, timeout=timeout)
        structured = result.get("structuredContent") if isinstance(result, dict) else None
        if isinstance(structured, dict):
            if structured.get("code") in {"action_outcome_mismatch", "typed_output_mismatch"}:
                raise VelaCUError(f"Cua Driver contract failure: {structured}")
            return structured
        if isinstance(result, dict):
            return result
        raise VelaCUError(f"Unexpected Cua result: {result!r}")

    def close(self) -> None:
        self._preflight_done = False
        self._stop_daemon()

    def click(self, *, pid: int, window_id: int, window_width: float, window_height: float,
              x: float, y: float, button: str = "left", count: int = 1) -> dict[str, Any]:
        if button != "left":
            raise VelaCUError("VelaCU pixel-only backend currently supports left click only")
        local_x = float(window_width) * x / 10.0
        local_y = float(window_height) * y / 10.0
        result = self._call("click", {
            "pid": int(pid),
            "window_id": int(window_id),
            "x": local_x,
            "y": local_y,
            "count": int(count),
        })
        # This bridge calls only the dedicated VelaCU XY click tool. The public
        # Cua projection intentionally keeps its legacy synthetic_events route
        # and may omit the tool's private `mode`, so normalize at this adapter
        # boundary and retain the raw route for audit.
        result = dict(result)
        result["cua_public_route"] = result.get("route")
        result["route"] = "skylight_cgevent_xy"
        result["ax_used"] = False
        result["physical_cursor_moved"] = False
        result["virtual_cursor_visible"] = bool(result.get("agent_cursor_visible", True))
        result.update({
            "mode": "cua-pixel-only",
            "normalizedX": x,
            "normalizedY": y,
            "windowLocalX": local_x,
            "windowLocalY": local_y,
            "windowWidth": float(window_width),
            "windowHeight": float(window_height),
        })
        return result


def _run_json(args: list[str], timeout: float = 3.0) -> Any:
    proc = subprocess.run(
        [str(HELPER), *args],
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    if proc.returncode != 0:
        msg = proc.stderr.strip() or proc.stdout.strip() or f"helper exit {proc.returncode}"
        raise VelaCUError(msg)
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise VelaCUError(f"Bad helper JSON: {proc.stdout[:200]!r}") from exc


def list_windows() -> list[dict[str, Any]]:
    return _run_json(["list"])


def get_window(window_id: int) -> dict[str, Any]:
    return _run_json(["get", str(int(window_id))])


def choose_window(query: str | None = None, window_id: int | None = None) -> dict[str, Any]:
    windows = list_windows()
    if window_id is not None:
        for w in windows:
            if int(w["windowID"]) == int(window_id):
                return w
        raise VelaCUError(f"Window id {window_id} not found")

    q = (query or "").strip().casefold()
    if not q:
        raise VelaCUError("Provide query or window_id")

    def score(w: dict[str, Any]) -> tuple[int, int, float]:
        owner = str(w.get("owner", "")).casefold()
        title_raw = str(w.get("title", "")).strip()
        title = title_raw.casefold()
        exact = int(q == owner or q == title)
        starts = int(owner.startswith(q) or title.startswith(q))
        contains = int(q in owner or q in title)
        titled = int(bool(title_raw))
        area = float(w.get("width", 0)) * float(w.get("height", 0))
        return exact * 100 + starts * 10 + contains, titled, area

    candidates = [w for w in windows if score(w)[0] > 0]
    if not candidates:
        names = sorted({str(w.get("owner", "")) for w in windows if w.get("owner")})
        raise VelaCUError(f"No window matching {query!r}. Visible owners: {', '.join(names[:20])}")
    return max(candidates, key=score)


def capture_window_png(window_id: int) -> bytes:
    # -o removes the macOS window shadow. This is important: the returned image then
    # maps exactly to the CGWindow bounds (apart from Retina scale), so normalized
    # coordinates stay correct even after arbitrary image down-scaling.
    fd, temp_path = tempfile.mkstemp(prefix="velacu-", suffix=".png")
    os.close(fd)
    try:
        proc = subprocess.run(
            [str(SCREENCAPTURE), "-x", "-o", f"-l{int(window_id)}", temp_path],
            capture_output=True,
            timeout=3.0,
            check=False,
        )
        if proc.returncode != 0:
            raise VelaCUError(proc.stderr.decode("utf-8", "replace").strip() or "screencapture failed")
        data = Path(temp_path).read_bytes()
        if len(data) < 100:
            raise VelaCUError("screencapture returned an empty image")
        return data
    finally:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass


def _font(size: int = 11) -> ImageFont.ImageFont:
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def add_ruler(raw_png: bytes, max_width: int = 640, margin: int = 38) -> tuple[bytes, dict[str, int]]:
    with Image.open(io.BytesIO(raw_png)) as src:
        src = src.convert("RGB")
        raw_w, raw_h = src.size
        max_width = max(320, min(int(max_width), 1600))
        if raw_w > max_width:
            scale = max_width / raw_w
            w = max_width
            h = max(1, round(raw_h * scale))
            content = src.resize((w, h), Image.Resampling.LANCZOS)
        else:
            content = src.copy()
            w, h = content.size

    canvas = Image.new("RGB", (w + margin * 2, h + margin * 2), "white")
    canvas.paste(content, (margin, margin))

    # Semi-transparent 1.0-step major grid over the clickable content.
    # Only integer grid lines cross the UI; 0.1 subdivisions remain on the outer ruler.
    overlay = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    grid = ImageDraw.Draw(overlay)
    for major in range(1, 10):
        frac = major / 10.0
        px = margin + round((w - 1) * frac)
        py = margin + round((h - 1) * frac)
        grid.line((px, margin, px, margin + h - 1), fill=(0, 0, 0, 48), width=1)
        grid.line((margin, py, margin + w - 1, py), fill=(0, 0, 0, 48), width=1)
    canvas = Image.alpha_composite(canvas.convert("RGBA"), overlay).convert("RGB")

    draw = ImageDraw.Draw(canvas)
    font = _font(11)

    # Thin border around the actual clickable content.
    draw.rectangle((margin, margin, margin + w - 1, margin + h - 1), outline="black", width=1)

    for i in range(101):
        frac = i / 100.0
        px = margin + round((w - 1) * frac)
        py = margin + round((h - 1) * frac)

        if i % 10 == 0:
            tick = 11
            line_w = 2
        elif i % 5 == 0:
            tick = 7
            line_w = 1
        else:
            tick = 4
            line_w = 1

        # x ruler, top + bottom
        draw.line((px, margin, px, margin - tick), fill="black", width=line_w)
        draw.line((px, margin + h - 1, px, margin + h - 1 + tick), fill="black", width=line_w)
        # y ruler, left + right
        draw.line((margin, py, margin - tick, py), fill="black", width=line_w)
        draw.line((margin + w - 1, py, margin + w - 1 + tick, py), fill="black", width=line_w)

        if i % 10 == 0:
            label = str(i // 10)
            # Pillow anchor='mm' keeps 0 and 10 centered on their exact endpoints.
            draw.text((px, margin - 23), label, fill="black", font=font, anchor="mm")
            draw.text((px, margin + h + 22), label, fill="black", font=font, anchor="mm")
            draw.text((margin - 23, py), label, fill="black", font=font, anchor="mm")
            draw.text((margin + w + 22, py), label, fill="black", font=font, anchor="mm")

    out = io.BytesIO()
    canvas.save(out, format="PNG", optimize=True)
    return out.getvalue(), {
        "raw_width": raw_w,
        "raw_height": raw_h,
        "content_width": w,
        "content_height": h,
        "output_width": canvas.width,
        "output_height": canvas.height,
        "margin": margin,
    }


class VelaCUCore:
    def __init__(self) -> None:
        self.bound_window_id: int | None = None
        self.bound_app: str | None = None
        self.bound_size: tuple[float, float] | None = None
        self.latest_raw_size: tuple[int, int] | None = None
        self.cua = CuaClickBridge()
        self.session_id = f"{os.getpid()}-{uuid.uuid4().hex[:12]}"
        self.server_id = f"velacu-{self.session_id}"
        self._status_active = False
        self._status_stop = threading.Event()
        self._status_thread = threading.Thread(target=self._watch_status_commands, name="velacu-status-command", daemon=True)
        self._status_thread.start()
        atexit.register(self._shutdown_status)

    def _status_async(self, command: str, payload: dict[str, Any] | None = None) -> None:
        """Publish only on lifecycle transitions; never wait for the observer."""
        if not STATUS_PUBLISHER.exists():
            return
        args = [sys.executable, str(STATUS_PUBLISHER), command, "--session", self.session_id]
        if payload is not None:
            args.extend(["--payload", json.dumps(payload, ensure_ascii=False, separators=(",", ":"))])
        try:
            subprocess.Popen(
                args,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError:
            # Status Bar is an observer. A missing/broken observer must never
            # change the result of a VelaCU operation.
            pass

    def _publish_active(self, window: dict[str, Any]) -> None:
        self._status_active = True
        self._status_async(
            "publish",
            {
                "active": True,
                "server_pid": os.getpid(),
                "server_id": self.server_id,
                "target_pid": int(window["pid"]),
                "bundle_id": str(window.get("bundleID") or ""),
                "bundle_path": str(window.get("bundlePath") or ""),
                "owner": str(window.get("owner") or ""),
                "title": str(window.get("title") or ""),
            },
        )

    def _publish_release(self) -> None:
        if self._status_active:
            self._status_active = False
            self._status_async("release")

    def _watch_status_commands(self) -> None:
        command = STATUS_COMMANDS / f"{self.session_id}.release"
        while not self._status_stop.wait(0.10):
            if not command.exists():
                continue
            try:
                command.unlink()
            except FileNotFoundError:
                continue
            try:
                self.release()
            except Exception:
                # The normal MCP request path remains authoritative; a menu
                # command must not crash the server thread.
                pass

    def _shutdown_status(self) -> None:
        self._status_stop.set()
        self._publish_release()

    def bind(self, query: str | None = None, window_id: int | None = None) -> dict[str, Any]:
        window = choose_window(query=query, window_id=window_id)
        app = str(window.get("bundlePath") or window.get("bundleID") or window.get("owner") or "").strip()
        if not app:
            raise VelaCUError("Could not resolve an app identifier for the selected window")
        # Preflight the private pixel-only backend before a timed CU run starts.
        self.cua.preflight()
        same_window = self.bound_window_id == int(window["windowID"]) and self.bound_app == app
        self.bound_window_id = int(window["windowID"])
        self.bound_app = app
        self.bound_size = (float(window["width"]), float(window["height"]))
        window["clickBackend"] = "cua-pixel-only"
        window["reusedBinding"] = same_window
        self._publish_active(window)
        return window

    def bound(self) -> dict[str, Any]:
        if self.bound_window_id is None:
            raise VelaCUError("No VelaCU window is bound")
        try:
            return get_window(self.bound_window_id)
        except VelaCUError:
            self.bound_window_id = None
            self.bound_app = None
            self.bound_size = None
            self._publish_release()
            raise VelaCUError("The bound window no longer exists. Bind again.")

    def capture(self, max_width: int = 640) -> tuple[bytes, dict[str, Any]]:
        window = self.bound()
        raw = capture_window_png(int(window["windowID"]))
        ruled, meta = add_ruler(raw, max_width=max_width)
        self.latest_raw_size = (int(meta["raw_width"]), int(meta["raw_height"]))
        latest = RUNTIME / "latest_ruled.png"
        latest.write_bytes(ruled)
        return ruled, {"window": window, **meta, "latest": str(latest)}

    def click(self, x: float, y: float, button: str = "left", count: int = 1) -> dict[str, Any]:
        window = self.bound()
        x = round(float(x), 1)
        y = round(float(y), 1)
        if not (0.0 <= x <= 10.0 and 0.0 <= y <= 10.0):
            raise VelaCUError("x and y must both be in the inclusive range 0..10")
        if button not in {"left", "right", "middle"}:
            raise VelaCUError("button must be left, right, or middle")
        count = max(1, min(int(count), 4))
        self.bound_size = (float(window["width"]), float(window["height"]))
        return self.cua.click(
            pid=int(window["pid"]),
            window_id=int(window["windowID"]),
            window_width=float(window["width"]),
            window_height=float(window["height"]),
            x=x,
            y=y,
            button=button,
            count=count,
        )

    def key(self, key: str) -> dict[str, Any]:
        window = self.bound()
        if not isinstance(key, str) or not key.strip():
            raise VelaCUError("key must be a non-empty string")
        result = _run_json(["key", str(int(window["windowID"])), key], timeout=3.0)
        return {"ok": bool(result.get("ok", True)), "key": key}

    def type_text(self, text: str) -> dict[str, Any]:
        window = self.bound()
        if not isinstance(text, str):
            raise VelaCUError("text must be a string")
        result = _run_json(["type", str(int(window["windowID"])), text], timeout=max(3.0, min(30.0, 0.25 + len(text) * 0.05)))
        return {"ok": bool(result.get("ok", True)), "characters": int(result.get("characters", len(text)))}

    def release(self) -> dict[str, Any]:
        self.cua.close()
        self.bound_window_id = None
        self.bound_app = None
        self.bound_size = None
        self.latest_raw_size = None
        self._publish_release()
        return {"released": True, "backend": "cua-pixel-only"}
