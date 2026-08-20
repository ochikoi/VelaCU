#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(PYTHONPATH="$ROOT" python3 -c 'from velacu_core import VELACU_VERSION; print(VELACU_VERSION)')"
ARCH="$(uname -m)"
NAME="velacu-${VERSION}-macos-${ARCH}"
DIST="$ROOT/dist"
STAGE="$DIST/$NAME"

for file in VelaCUHelper VelaClick VelaPointer; do
  [[ -x "$ROOT/bin/$file" ]] || { echo "error: build.sh must produce $file" >&2; exit 2; }
done
[[ -x "$ROOT/bin/VelaCU Status.app/Contents/MacOS/VelaCUStatus" ]] || { echo "error: status app is missing" >&2; exit 2; }

rm -rf "$STAGE"
mkdir -p "$STAGE/bin"

for file in install.sh build.sh velacu_core.py velacu_mcp.py status_publisher.py velacu_cli.py requirements.txt README.md CHANGELOG.md LICENSE THIRD_PARTY_NOTICES.md codex-mcp.example.toml generic-mcp.example.json; do
  cp "$ROOT/$file" "$STAGE/$file"
done
for dir in native scripts fixtures resources; do
  cp -R "$ROOT/$dir" "$STAGE/$dir"
done
for file in VelaCUHelper VelaClick VelaPointer; do
  cp "$ROOT/bin/$file" "$STAGE/bin/$file"
done
cp -R "$ROOT/bin/VelaCU Status.app" "$STAGE/bin/VelaCU Status.app"
chmod +x "$STAGE/install.sh" "$STAGE/build.sh" "$STAGE/scripts/package_release.sh" "$STAGE/scripts/package_source.sh" "$STAGE/bin/VelaCUHelper" "$STAGE/bin/VelaClick" "$STAGE/bin/VelaPointer" "$STAGE/bin/VelaCU Status.app/Contents/MacOS/VelaCUStatus"

(
  cd "$DIST"
  rm -f "$NAME.tar.gz"
  tar -czf "$NAME.tar.gz" "$NAME"
)

shasum -a 256 "$DIST/$NAME.tar.gz" > "$DIST/$NAME.tar.gz.sha256"
echo "$DIST/$NAME.tar.gz"
