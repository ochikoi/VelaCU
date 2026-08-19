#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(PYTHONPATH="$ROOT" python3 -c 'from velacu_core import VELACU_VERSION; print(VELACU_VERSION)')"
ARCH="$(uname -m)"
NAME="velacu-${VERSION}-macos-${ARCH}"
DIST="$ROOT/dist"
STAGE="$DIST/$NAME"

[[ -x "$ROOT/bin/VelaCUHelper" ]] || { echo "error: build VelaCU first" >&2; exit 2; }
[[ -x "$ROOT/bin/velacu-cua-driver" ]] || { echo "error: VelaCU driver is missing" >&2; exit 2; }
[[ -x "$ROOT/bin/VelaCU Status.app/Contents/MacOS/VelaCUStatus" ]] || { echo "error: status app is missing" >&2; exit 2; }

rm -rf "$STAGE"
mkdir -p "$STAGE/bin"

for file in install.sh build.sh velacu_core.py velacu_mcp.py status_publisher.py velacu_cli.py requirements.txt README.md LICENSE THIRD_PARTY_NOTICES.md codex-mcp.example.toml generic-mcp.example.json; do
  cp "$ROOT/$file" "$STAGE/$file"
done
for dir in native scripts third_party fixtures; do
  cp -R "$ROOT/$dir" "$STAGE/$dir"
done
cp "$ROOT/bin/VelaCUHelper" "$STAGE/bin/VelaCUHelper"
cp "$ROOT/bin/velacu-cua-driver" "$STAGE/bin/velacu-cua-driver"
cp -R "$ROOT/bin/VelaCU Status.app" "$STAGE/bin/VelaCU Status.app"
chmod +x "$STAGE/install.sh" "$STAGE/build.sh" "$STAGE/scripts/build_cua_driver.sh" "$STAGE/bin/VelaCUHelper" "$STAGE/bin/velacu-cua-driver" "$STAGE/bin/VelaCU Status.app/Contents/MacOS/VelaCUStatus"

(
  cd "$DIST"
  rm -f "$NAME.tar.gz"
  tar -czf "$NAME.tar.gz" "$NAME"
)

shasum -a 256 "$DIST/$NAME.tar.gz" > "$DIST/$NAME.tar.gz.sha256"
echo "$DIST/$NAME.tar.gz"
