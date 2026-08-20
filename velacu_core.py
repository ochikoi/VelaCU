#!/usr/bin/env python3
from __future__ import annotations

import io
import atexit
import json
import os
import select
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
VELACLICK = ROOT / "bin" / "VelaClick"
SCREENCAPTURE = Path("/usr/sbin/screencapture")
RUNTIME = ROOT / "runtime"
RUNTIME.mkdir(exist_ok=True)
POINTER_HELPER = ROOT / "bin" / "VelaPointer"
DEFAULT_POINTER_IMAGE = ROOT / "resources" / "VelaCUPointer.png"
STATUS_PUBLISHER = ROOT / "status_publisher.py"
STATUS_COMMANDS = RUNTIME / "status" / "commands"
VELACU_VERSION = "0.4.1"
VELACU_BUILD = "native-20260820-04"
MODEL_CAPTURE_WIDTH = 640


class VelaCUError(RuntimeError):
    pass


class VelaPointerBridge:
    """Independent click-through cursor layer pinned at target window z + 1."""

    def __init__(self) -> None:
        self.proc: subprocess.Popen[bytes] | None = None
        self._log_handle = None
        self._lock = threading.Lock()
        self.log_path = RUNTIME / f"velapointer-{os.getpid()}.log"
        atexit.register(self.close)

    def _image_path(self) -> Path:
        configured = os.environ.get("VELACU_POINTER_IMAGE", "").strip()
        return Path(configured).expanduser() if configured else DEFAULT_POINTER_IMAGE

    def _stop_process(self) -> None:
        proc = self.proc
        self.proc = None
        if proc is not None:
            try:
                if proc.stdin is not None:
                    proc.stdin.close()
            except OSError:
                pass
            try:
                if proc.stdout is not None:
                    proc.stdout.close()
            except OSError:
                pass
            if proc.poll() is None:
                try:
                    proc.terminate()
                    proc.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    try:
                        proc.wait(timeout=0.5)
                    except subprocess.TimeoutExpired:
                        pass
        handle = self._log_handle
        self._log_handle = None
        if handle is not None:
            try:
                handle.close()
            except OSError:
                pass

    def _ensure(self) -> bool:
        if (
            self.proc is not None
            and self.proc.poll() is None
            and self.proc.stdin is not None
            and self.proc.stdout is not None
        ):
            return True
        self._stop_process()
        image = self._image_path()
        if not POINTER_HELPER.exists() or not image.exists():
            return False
        try:
            self._log_handle = self.log_path.open("ab")
            self.proc = subprocess.Popen(
                [str(POINTER_HELPER), str(image)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=self._log_handle,
                start_new_session=True,
            )
            return self.proc.stdin is not None and self.proc.stdout is not None
        except OSError:
            self._stop_process()
            return False

    def _send(self, payload: dict[str, Any]) -> bool:
        wire = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"
        with self._lock:
            for _ in range(2):
                if not self._ensure():
                    return False
                assert self.proc is not None and self.proc.stdin is not None
                try:
                    self.proc.stdin.write(wire)
                    self.proc.stdin.flush()
                    return True
                except (BrokenPipeError, OSError):
                    self._stop_process()
            return False

    def move(self, window: dict[str, Any], x: float, y: float) -> bool:
        screen_x = float(window.get("x", 0.0)) + float(window["width"]) * x / 10.0
        screen_y = float(window.get("y", 0.0)) + float(window["height"]) * y / 10.0
        request_id = uuid.uuid4().hex
        payload = {
            "action": "move",
            "window_id": int(window["windowID"]),
            "screen_x": screen_x,
            "screen_y": screen_y,
            "local_x": float(window["width"]) * x / 10.0,
            "local_y": float(window["height"]) * y / 10.0,
            "pulse": False,
            "request_id": request_id,
        }
        wire = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"

        with self._lock:
            if not self._ensure():
                return False
            assert self.proc is not None and self.proc.stdin is not None and self.proc.stdout is not None
            try:
                self.proc.stdin.write(wire)
                self.proc.stdin.flush()
            except (BrokenPipeError, OSError):
                self._stop_process()
                return False

            deadline = time.monotonic() + 0.75
            while time.monotonic() < deadline:
                remaining = max(0.0, deadline - time.monotonic())
                try:
                    ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
                except (OSError, ValueError):
                    self._stop_process()
                    return False
                if not ready:
                    break
                line = self.proc.stdout.readline()
                if not line:
                    self._stop_process()
                    return False
                try:
                    response = json.loads(line.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if response.get("event") == "arrived" and response.get("request_id") == request_id:
                    return True

            # A visual cursor that cannot confirm arrival must not remain on screen
            # while the real click proceeds at a different point. Drop only the
            # cosmetic Pointer process; the click executor remains independent.
            self._stop_process()
            return False

    def pulse(self) -> bool:
        return self._send({"action": "pulse"})

    def hide(self) -> None:
        with self._lock:
            if self.proc is None or self.proc.poll() is not None or self.proc.stdin is None:
                return
            try:
                self.proc.stdin.write(b'{"action":"hide"}\n')
                self.proc.stdin.flush()
            except (BrokenPipeError, OSError):
                self._stop_process()

    def close(self) -> None:
        with self._lock:
            self._stop_process()


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


def _run_velaclick(args: list[str], timeout: float = 3.0) -> Any:
    proc = subprocess.run(
        [str(VELACLICK), *args],
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    if proc.returncode != 0:
        msg = proc.stderr.strip() or proc.stdout.strip() or f"VelaClick exit {proc.returncode}"
        raise VelaCUError(msg)
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise VelaCUError(f"Bad VelaClick JSON: {proc.stdout[:200]!r}") from exc


def list_windows() -> list[dict[str, Any]]:
    return _run_json(["list"])


def get_window(window_id: int) -> dict[str, Any]:
    return _run_json(["get", str(int(window_id))])


def has_system_settings_remote_view(window: dict[str, Any]) -> bool:
    """Return true when System Settings is hosting a same-frame app-extension pane.

    macOS renders many right-hand settings panes in a separate app-extension
    process whose CoreGraphics window has the same frame as the System Settings
    host. PID-targeted events to either process can miss the RemoteView boundary;
    these panes require a normal WindowServer HID hit-test instead.
    """
    if str(window.get("bundleID") or "") != "com.apple.systempreferences":
        return False
    x = float(window.get("x", 0.0))
    y = float(window.get("y", 0.0))
    width = float(window.get("width", 0.0))
    height = float(window.get("height", 0.0))
    host_pid = int(window.get("pid", 0))
    host_id = int(window.get("windowID", 0))
    for candidate in list_windows():
        if int(candidate.get("windowID", 0)) == host_id or int(candidate.get("pid", 0)) == host_pid:
            continue
        bundle_id = str(candidate.get("bundleID") or "")
        if not bundle_id.startswith("com.apple."):
            continue
        if (
            abs(float(candidate.get("x", 0.0)) - x) <= 1.0
            and abs(float(candidate.get("y", 0.0)) - y) <= 1.0
            and abs(float(candidate.get("width", 0.0)) - width) <= 1.0
            and abs(float(candidate.get("height", 0.0)) - height) <= 1.0
        ):
            return True
    return False


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
        self._lifecycle_lock = threading.RLock()
        self.bound_window_id: int | None = None
        self.bound_app: str | None = None
        self.bound_size: tuple[float, float] | None = None
        self.latest_raw_size: tuple[int, int] | None = None
        self.pointer = VelaPointerBridge()
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
                "window_id": int(window["windowID"]),
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
        with self._lifecycle_lock:
            return self._bind_locked(query=query, window_id=window_id)

    def _bind_locked(self, query: str | None = None, window_id: int | None = None) -> dict[str, Any]:
        window = choose_window(query=query, window_id=window_id)
        app = str(window.get("bundlePath") or window.get("bundleID") or window.get("owner") or "").strip()
        if not app:
            raise VelaCUError("Could not resolve an app identifier for the selected window")
        same_window = self.bound_window_id == int(window["windowID"]) and self.bound_app == app
        if not same_window:
            self.pointer.hide()
        self.bound_window_id = int(window["windowID"])
        self.bound_app = app
        self.bound_size = (float(window["width"]), float(window["height"]))
        window["clickBackend"] = "VelaClick-0.3.0-SkyLight"
        window["reusedBinding"] = same_window
        self._publish_active(window)
        return window

    def bound(self) -> dict[str, Any]:
        with self._lifecycle_lock:
            return self._bound_locked()

    def _bound_locked(self) -> dict[str, Any]:
        if self.bound_window_id is None:
            raise VelaCUError("No VelaCU window is bound")
        try:
            return get_window(self.bound_window_id)
        except VelaCUError:
            self.pointer.hide()
            self.bound_window_id = None
            self.bound_app = None
            self.bound_size = None
            self._publish_release()
            raise VelaCUError("The bound window no longer exists. Bind again.")

    def capture(self, max_width: int = 640) -> tuple[bytes, dict[str, Any]]:
        with self._lifecycle_lock:
            window = self._bound_locked()
            raw = capture_window_png(int(window["windowID"]))
            ruled, meta = add_ruler(raw, max_width=max_width)
            self.latest_raw_size = (int(meta["raw_width"]), int(meta["raw_height"]))
            latest = RUNTIME / "latest_ruled.png"
            latest.write_bytes(ruled)
            return ruled, {"window": window, **meta, "latest": str(latest)}

    def click(self, x: float, y: float, button: str = "left", count: int = 1) -> dict[str, Any]:
        with self._lifecycle_lock:
            window = self._bound_locked()
            x = round(float(x), 1)
            y = round(float(y), 1)
            if not (0.0 <= x <= 10.0 and 0.0 <= y <= 10.0):
                raise VelaCUError("x and y must both be in the inclusive range 0..10")
            if button not in {"left", "right", "middle"}:
                raise VelaCUError("button must be left, right, or middle")
            count = max(1, min(int(count), 4))
            self.bound_size = (float(window["width"]), float(window["height"]))
            pointer_visible = self.pointer.move(window, x, y)
            if pointer_visible:
            # Purely cosmetic click pulse: movement arrival gates the real click,
            # but the bounce does not depend on click delivery or click success.
                self.pointer.pulse()

        # System Settings hosts many right-hand panes in a same-frame app-extension
        # RemoteView. PID-targeted background CGEvents reach the host/sidebar but
        # not the embedded pane. For that one topology, use an untargeted HID hit
        # test while briefly activating/restoring the host; coordinates stay exactly
        # the same 0..10 window-local values and no AX/DOM lookup is involved.
            if button == "left" and count == 1 and has_system_settings_remote_view(window):
                permission = _run_json(["permissions"], timeout=3.0)
                if not bool(permission.get("postEventAccess")):
                    raise VelaCUError("VelaCU host lacks CGPostEvent access for RemoteView click")
                result = _run_json(
                    ["remoteview-click", str(int(window["windowID"])), f"{x:.1f}", f"{y:.1f}"],
                    timeout=5.0,
                )
                return {
                "delivery": {"mode": "foreground-transient"},
                "effect": "unverifiable",
                "route": "global_hid_remoteview",
                "ax_used": False,
                "physical_cursor_moved": False,
                "virtual_cursor_visible": pointer_visible,
                "mode": "remoteview-pixel-only",
                "atomic": True,
                "session_state": False,
                "normalizedX": x,
                "normalizedY": y,
                "windowLocalX": float(window["width"]) * x / 10.0,
                "windowLocalY": float(window["height"]) * y / 10.0,
                "windowWidth": float(window["width"]),
                "windowHeight": float(window["height"]),
                "cursorBeforeX": result.get("beforeX"),
                "cursorBeforeY": result.get("beforeY"),
                "cursorAfterX": result.get("afterX"),
                "cursorAfterY": result.get("afterY"),
                }

            local_x = float(window["width"]) * x / 10.0
            local_y = float(window["height"]) * y / 10.0
            screen_x = float(window["x"]) + local_x
            screen_y = float(window["y"]) + local_y
            result: dict[str, Any] = {}
            for index in range(count):
                result = dict(_run_velaclick(
                    [
                        "click",
                        button,
                        str(int(window["pid"])),
                        str(int(window["windowID"])),
                        f"{screen_x:.3f}",
                        f"{screen_y:.3f}",
                        f"{local_x:.3f}",
                        f"{local_y:.3f}",
                    ],
                    timeout=5.0,
                ))
                if index + 1 < count:
                    time.sleep(0.045)
            result.update({
                "route": "velaclick_skylight_xy",
                "ax_used": False,
                "physical_cursor_moved": False,
                "virtual_cursor_visible": pointer_visible,
                "mode": "velacu-native-pixel-only",
                "atomic": True,
                "session_state": False,
                "normalizedX": x,
                "normalizedY": y,
                "windowLocalX": local_x,
                "windowLocalY": local_y,
                "windowWidth": float(window["width"]),
                "windowHeight": float(window["height"]),
            })
            return result

    def scroll(self, direction: str, amount: int = 3, x: float = 5.0, y: float = 5.0) -> dict[str, Any]:
        with self._lifecycle_lock:
            window = self._bound_locked()
            x = round(float(x), 1)
            y = round(float(y), 1)
            if not (0.0 <= x <= 10.0 and 0.0 <= y <= 10.0):
                raise VelaCUError("x and y must both be in the inclusive range 0..10")
            direction = str(direction).lower()
            if direction not in {"up", "down", "left", "right"}:
                raise VelaCUError("direction must be up, down, left, or right")
            amount = max(1, min(int(amount), 10))
            pointer_visible = self.pointer.move(window, x, y)
            result = _run_json(
                ["scroll-atomic", str(int(window["windowID"])), f"{x:.1f}", f"{y:.1f}", direction, str(amount)],
                timeout=5.0,
            )
            result = dict(result)
            result.update({
                "route": "velacu_native_skylight_scroll",
                "ax_used": False,
                "physical_cursor_moved": False,
                "virtual_cursor_visible": pointer_visible,
                "session_state": False,
            })
            return result

    def key(self, key: str) -> dict[str, Any]:
        with self._lifecycle_lock:
            window = self._bound_locked()
            if not isinstance(key, str) or not key.strip():
                raise VelaCUError("key must be a non-empty string")
            result = _run_json(["key", str(int(window["windowID"])), key], timeout=3.0)
            return {"ok": bool(result.get("ok", True)), "key": key}

    def type_text(self, text: str) -> dict[str, Any]:
        with self._lifecycle_lock:
            window = self._bound_locked()
            if not isinstance(text, str):
                raise VelaCUError("text must be a string")
            result = _run_json(["type", str(int(window["windowID"])), text], timeout=max(3.0, min(30.0, 0.25 + len(text) * 0.05)))
            return {"ok": bool(result.get("ok", True)), "characters": int(result.get("characters", len(text)))}

    def release(self) -> dict[str, Any]:
        with self._lifecycle_lock:
            self.pointer.close()
            self.bound_window_id = None
            self.bound_app = None
            self.bound_size = None
            self.latest_raw_size = None
            self._publish_release()
            return {"released": True, "backend": "velacu-native-pixel-only", "session_state": False}
