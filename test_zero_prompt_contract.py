#!/usr/bin/env python3
from __future__ import annotations

import unittest

from velacu_core import MODEL_CAPTURE_WIDTH
from velacu_mcp import TOOLS, handle


class ZeroPromptContractTests(unittest.TestCase):
    def tool(self, name: str) -> dict:
        return next(tool for tool in TOOLS if tool["name"] == name)

    def test_model_capture_width_is_fixed(self) -> None:
        self.assertEqual(MODEL_CAPTURE_WIDTH, 640)

    def test_capture_does_not_expose_width_choice(self) -> None:
        capture = self.tool("velacu_capture")
        self.assertEqual(capture["inputSchema"]["properties"], {})
        description = capture["description"].lower()
        self.assertIn("640", description)
        self.assertIn("top-left", description)
        self.assertIn("bottom", description)

    def test_click_does_not_expose_width_choice(self) -> None:
        click = self.tool("velacu_click")
        self.assertNotIn("max_width", click["inputSchema"]["properties"])
        description = click["description"].lower()
        self.assertIn("0..10", description)
        self.assertIn("one decimal", description)
        self.assertIn("lower targets", description)

    def test_click_schema_avoids_float_multiple_of_validation(self) -> None:
        click = self.tool("velacu_click")
        properties = click["inputSchema"]["properties"]
        for axis in ("x", "y"):
            self.assertNotIn("multipleOf", properties[axis])
            self.assertEqual(properties[axis]["minimum"], 0)
            self.assertEqual(properties[axis]["maximum"], 10)
            self.assertIn("one decimal", properties[axis]["description"].lower())

    def test_initialize_advertises_tool_list_changes(self) -> None:
        response = handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
        self.assertIsNotNone(response)
        self.assertTrue(response["result"]["capabilities"]["tools"]["listChanged"])


if __name__ == "__main__":
    unittest.main()
