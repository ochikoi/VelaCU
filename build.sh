#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${PYTHON:-python3}"

command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found. Install Xcode Command Line Tools." >&2; exit 2; }
"$PYTHON" -c 'import PIL; print("Pillow", PIL.__version__)' >/dev/null 2>&1 || {
  echo "error: Pillow is missing for $PYTHON. Install with: $PYTHON -m pip install Pillow" >&2
  exit 2
}

mkdir -p "$ROOT/bin" "$ROOT/resources" "$ROOT/runtime/status/sessions" "$ROOT/runtime/status/commands"

swiftc "$ROOT/native/VelaCUHelper.swift" \
  -o "$ROOT/bin/VelaCUHelper" \
  -framework CoreGraphics \
  -framework AppKit

swiftc -parse-as-library "$ROOT/native/VelaClick.swift" \
  -o "$ROOT/bin/VelaClick" \
  -framework CoreGraphics \
  -framework AppKit

swiftc "$ROOT/native/VelaPointer.swift" \
  -o "$ROOT/bin/VelaPointer" \
  -framework AppKit \
  -framework CoreGraphics

chmod +x "$ROOT/bin/VelaCUHelper" "$ROOT/bin/VelaClick" "$ROOT/bin/VelaPointer"

STATUS_APP="$ROOT/bin/VelaCU Status.app"
rm -rf "$STATUS_APP"
mkdir -p "$STATUS_APP/Contents/MacOS" "$STATUS_APP/Contents/Resources"
test -f "$ROOT/resources/VelaCUPointerSource.png"
swiftc "$ROOT/native/PreparePointerAsset.swift" \
  -o "$ROOT/bin/PreparePointerAsset" \
  -framework CoreGraphics \
  -framework ImageIO
"$ROOT/bin/PreparePointerAsset" \
  "$ROOT/resources/VelaCUPointerSource.png" \
  "$ROOT/resources/VelaCUPointer.png"
cp "$ROOT/resources/VelaCUPointerSource.png" "$STATUS_APP/Contents/Resources/VelaCUPointerSource.png"
cp "$ROOT/resources/VelaCUPointer.png" "$STATUS_APP/Contents/Resources/VelaCUPointer.png"
rm -f "$ROOT/bin/PreparePointerAsset"
swiftc "$ROOT/native/VelaCUStatus.swift"   -o "$STATUS_APP/Contents/MacOS/VelaCUStatus"   -framework AppKit
cp "$ROOT/native/VelaCUStatus-Info.plist" "$STATUS_APP/Contents/Info.plist"
chmod +x "$STATUS_APP/Contents/MacOS/VelaCUStatus"

echo "Built VelaCU:"
echo "  helper:  $ROOT/bin/VelaCUHelper"
echo "  click:   $ROOT/bin/VelaClick (VelaClick 0.3.0 SkyLight)"
echo "  pointer: $ROOT/bin/VelaPointer"
echo "  status:  $STATUS_APP"
echo "  MCP:     $PYTHON $ROOT/velacu_mcp.py"
