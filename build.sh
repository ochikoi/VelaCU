#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${PYTHON:-python3}"

command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found. Install Xcode Command Line Tools." >&2; exit 2; }
"$PYTHON" -c 'import PIL; print("Pillow", PIL.__version__)' >/dev/null 2>&1 || {
  echo "error: Pillow is missing for $PYTHON. Install with: $PYTHON -m pip install Pillow" >&2
  exit 2
}

mkdir -p "$ROOT/bin" "$ROOT/runtime/status/sessions" "$ROOT/runtime/status/commands"

swiftc "$ROOT/native/VelaCUHelper.swift" \
  -o "$ROOT/bin/VelaCUHelper" \
  -framework CoreGraphics \
  -framework AppKit

STATUS_APP="$ROOT/bin/VelaCU Status.app"
rm -rf "$STATUS_APP"
mkdir -p "$STATUS_APP/Contents/MacOS" "$STATUS_APP/Contents/Resources"
swiftc "$ROOT/native/VelaCUStatus.swift" \
  -o "$STATUS_APP/Contents/MacOS/VelaCUStatus" \
  -framework AppKit
cp "$ROOT/native/VelaCUStatus-Info.plist" "$STATUS_APP/Contents/Info.plist"
chmod +x "$STATUS_APP/Contents/MacOS/VelaCUStatus"

if [[ ! -x "$ROOT/bin/velacu-cua-driver" || "${VELACU_REBUILD_CUA:-0}" == "1" ]]; then
  "$ROOT/scripts/build_cua_driver.sh"
fi

chmod +x "$ROOT/bin/VelaCUHelper" "$ROOT/bin/velacu-cua-driver"

echo "Built VelaCU:"
echo "  helper: $ROOT/bin/VelaCUHelper"
echo "  driver: $ROOT/bin/velacu-cua-driver"
echo "  status: $STATUS_APP"
echo "  MCP:    $PYTHON $ROOT/velacu_mcp.py"
