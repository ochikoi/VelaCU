#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(PYTHONPATH="$ROOT" python3 -c 'from velacu_core import VELACU_VERSION; print(VELACU_VERSION)')"
DIST="$ROOT/dist"
NAME="velacu-${VERSION}-source"
STAGE="$DIST/$NAME"

rm -rf "$STAGE"
mkdir -p "$STAGE"

python3 - "$ROOT" "$STAGE" <<'PY'
import shutil
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
skip_dirs = {'.git', '.build', '.venv', 'bin', 'dist', 'runtime', '__pycache__'}
skip_suffixes = {'.pyc'}
for path in src.rglob('*'):
    rel = path.relative_to(src)
    if any(part in skip_dirs for part in rel.parts):
        continue
    if path.is_dir():
        (dst / rel).mkdir(parents=True, exist_ok=True)
        continue
    if path.suffix in skip_suffixes or path.name == '.DS_Store':
        continue
    target = dst / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, target)
PY

chmod +x "$STAGE/install.sh" "$STAGE/build.sh" "$STAGE/scripts/package_release.sh" "$STAGE/scripts/package_source.sh" || true
python3 "$STAGE/scripts/verify_source_tree.py"

(
  cd "$DIST"
  rm -f "$NAME.tar.gz"
  tar -czf "$NAME.tar.gz" "$NAME"
)
shasum -a 256 "$DIST/$NAME.tar.gz" > "$DIST/$NAME.tar.gz.sha256"
echo "$DIST/$NAME.tar.gz"
