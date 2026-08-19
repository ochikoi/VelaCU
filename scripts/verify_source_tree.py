#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP_DIRS = {".git", ".build", ".venv", "bin", "dist", "runtime", "__pycache__"}
TEXT_SUFFIXES = {".py", ".swift", ".sh", ".md", ".toml", ".json", ".html", ".rs", ".txt", ".yml", ".yaml"}
FORBIDDEN = [
    re.compile(r"/Users/ochikoi"),
    re.compile(r"\bochikoi\b", re.IGNORECASE),
    re.compile(r"IMG_4702"),
    re.compile(r"LightCU"),
]
SECRET_PATTERNS = [
    re.compile(r"sk-[A-Za-z0-9_-]{20,}"),
    re.compile(r"ghp_[A-Za-z0-9]{20,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
]


def ignored(path: Path) -> bool:
    return path.resolve() == Path(__file__).resolve() or any(part in SKIP_DIRS for part in path.relative_to(ROOT).parts)


def main() -> int:
    problems = []
    for path in ROOT.rglob("*"):
        if not path.is_file() or ignored(path) or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for pattern in FORBIDDEN:
            if pattern.search(text):
                problems.append(f"{path.relative_to(ROOT)}: forbidden project/private marker: {pattern.pattern}")
        for pattern in SECRET_PATTERNS:
            if pattern.search(text):
                problems.append(f"{path.relative_to(ROOT)}: possible secret: {pattern.pattern}")
    if problems:
        print("Source-tree verification failed:")
        print("\n".join(f"- {item}" for item in problems))
        return 1
    print("Source-tree verification passed: no personal paths, old LightCU naming, pointer source asset names, or common token patterns found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
