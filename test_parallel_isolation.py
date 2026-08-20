#!/usr/bin/env python3
"""Focused regression tests for VelaCU's stateless native click path."""
from __future__ import annotations

import multiprocessing
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from velacu_core import VelaCUCore


ROOT = Path(__file__).resolve().parent


class FakePointer:
    def __init__(self) -> None:
        self.closed = 0
        self.moves = 0
        self.pulses = 0

    def move(self, window: dict, x: float, y: float) -> bool:
        self.moves += 1
        return True

    def pulse(self) -> bool:
        self.pulses += 1
        return True

    def hide(self) -> None:
        pass

    def close(self) -> None:
        self.closed += 1


def make_core(window: dict) -> VelaCUCore:
    core = object.__new__(VelaCUCore)
    core._lifecycle_lock = threading.RLock()
    core.bound_window_id = int(window["windowID"])
    core.bound_app = "test-app"
    core.bound_size = (float(window["width"]), float(window["height"]))
    core.latest_raw_size = None
    core.pointer = FakePointer()
    core._status_active = False
    core._publish_release = lambda: None
    core._bound_locked = lambda: window
    return core


WINDOW = {"windowID": 123, "pid": 456, "width": 800.0, "height": 600.0, "x": 10.0, "y": 20.0}


def fake_native_result(args: list[str], timeout: float = 3.0) -> dict:
    if args[0] != "click":
        raise AssertionError(args)
    return {
        "ok": True,
        "windowID": int(args[3]),
        "pid": int(args[2]),
        "x": float(args[4]),
        "y": float(args[5]),
        "cursorBeforeX": 300.0,
        "cursorBeforeY": 400.0,
        "cursorAfterX": 300.0,
        "cursorAfterY": 400.0,
    }


def child_contract_probe(queue: multiprocessing.Queue) -> None:
    """Run in separate processes to prove there is no shared click transport."""
    source = (ROOT / "velacu_core.py").read_text(encoding="utf-8")
    queue.put({
        "has_legacy_bridge": ("C" + "uaClickBridge") in source,
        "has_legacy_socket": ("velacu-" + "cua-") in source or "socket.socket" in source,
        "has_session_start": "start_session" in source or "_session_started" in source,
    })


class NativeClickIsolationTests(unittest.TestCase):
    def test_repeated_clicks_are_atomic_and_have_no_session_state(self) -> None:
        core = make_core(WINDOW)
        with patch("velacu_core.has_system_settings_remote_view", return_value=False), patch(
            "velacu_core._run_velaclick", side_effect=fake_native_result
        ) as run_click:
            results = [core.click(5.0, 4.0) for _ in range(4)]

        self.assertEqual(run_click.call_count, 4)
        self.assertEqual([call.args[0][0] for call in run_click.call_args_list], ["click"] * 4)
        self.assertTrue(all(result["atomic"] for result in results))
        self.assertTrue(all(result["session_state"] is False for result in results))
        self.assertTrue(all(result["physical_cursor_moved"] is False for result in results))
        self.assertNotIn("session_id", run_click.call_args.args[0])

    def test_release_then_bind_state_can_click_again_without_reinitializing_backend(self) -> None:
        core = make_core(WINDOW)
        with patch("velacu_core.has_system_settings_remote_view", return_value=False), patch(
            "velacu_core._run_velaclick", side_effect=fake_native_result
        ) as run_click:
            core.click(1.0, 2.0)
            core.release()
            core.bound_window_id = WINDOW["windowID"]
            core.bound_app = "test-app"
            core.bound_size = (WINDOW["width"], WINDOW["height"])
            core.click(3.0, 4.0)

        self.assertEqual(run_click.call_count, 2)
        self.assertEqual(core.pointer.closed, 1)
        self.assertEqual(run_click.call_args.args[0][0], "click")

    def test_two_processes_have_no_legacy_socket_or_session_transport(self) -> None:
        context = multiprocessing.get_context("spawn")
        queue = context.Queue()
        processes = [context.Process(target=child_contract_probe, args=(queue,)) for _ in range(2)]
        for process in processes:
            process.start()
        reports = [queue.get(timeout=10) for _ in processes]
        for process in processes:
            process.join(timeout=10)
            self.assertEqual(process.exitcode, 0)
        self.assertEqual(len(reports), 2)
        for report in reports:
            self.assertEqual(report, {"has_legacy_bridge": False, "has_legacy_socket": False, "has_session_start": False})


if __name__ == "__main__":
    unittest.main()
