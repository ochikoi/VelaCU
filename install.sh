#!/bin/zsh
set -euo pipefail

SOURCE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_ROOT="${VELACU_HOME:-$HOME/.local/share/velacu}"
BIN_DIR="${VELACU_BIN_DIR:-$HOME/.local/bin}"
TARGET="codex"
FORCE_REBUILD=0
PYTHON_BIN="${PYTHON:-$(command -v python3 || true)}"

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --target codex|none   Configure Codex automatically (default: codex).
  --prefix PATH         Install VelaCU under PATH.
  --bin-dir PATH        Put the `velacu` launcher in PATH.
  --rebuild             Ignore bundled macOS binaries and rebuild locally.
  --python PATH         Python 3.9+ interpreter to use.
  -h, --help            Show this help.

A release archive can include prebuilt macOS binaries, so installation normally
needs only Python and Pillow. A plain source checkout builds the small native
macOS helpers locally and needs Xcode Command Line Tools.

The installer never removes unrelated Codex MCP servers. Before changing Codex,
VelaCU creates a timestamped backup of ~/.codex/config.toml.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --prefix) INSTALL_ROOT="$2"; shift 2 ;;
    --bin-dir) BIN_DIR="$2"; shift 2 ;;
    --rebuild) FORCE_REBUILD=1; shift ;;
    --python) PYTHON_BIN="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$TARGET" == "codex" || "$TARGET" == "none" ]] || { echo "error: --target must be codex or none" >&2; exit 2; }
[[ "$(uname -s)" == "Darwin" ]] || { echo "error: VelaCU currently supports macOS only" >&2; exit 2; }
[[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] || { echo "error: python3 was not found" >&2; exit 2; }
"$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,9) else 1)' || { echo "error: Python 3.9+ is required" >&2; exit 2; }

PREBUILT_READY=0
if [[ $FORCE_REBUILD -eq 0 \
   && -x "$SOURCE/bin/VelaCUHelper" \
   && -x "$SOURCE/bin/VelaClick" \
   && -x "$SOURCE/bin/VelaPointer" \
   && -x "$SOURCE/bin/VelaCU Status.app/Contents/MacOS/VelaCUStatus" ]]; then
  PREBUILT_READY=1
fi

if [[ $PREBUILT_READY -eq 0 ]]; then
  command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc is missing. Run: xcode-select --install" >&2; exit 2; }
fi

INSTALL_ROOT="${INSTALL_ROOT:A}"
BIN_DIR="${BIN_DIR:A}"
PARENT="${INSTALL_ROOT:h}"
BACKUP="$INSTALL_ROOT.velacu-backup-$$"

mkdir -p "$PARENT" "$BIN_DIR"
if [[ -e "$INSTALL_ROOT" ]]; then
  rm -rf "$BACKUP"
  mv "$INSTALL_ROOT" "$BACKUP"
fi

restore_on_error() {
  local code=$?
  if (( code != 0 )); then
    echo "VelaCU install failed; restoring the previous install." >&2
    rm -rf "$INSTALL_ROOT"
    if [[ -e "$BACKUP" ]]; then mv "$BACKUP" "$INSTALL_ROOT"; fi
  fi
  exit $code
}
trap restore_on_error EXIT

mkdir -p "$INSTALL_ROOT"
for file in velacu_core.py velacu_mcp.py status_publisher.py velacu_cli.py build.sh requirements.txt LICENSE THIRD_PARTY_NOTICES.md README.md CHANGELOG.md; do
  cp "$SOURCE/$file" "$INSTALL_ROOT/$file"
done
for dir in native scripts fixtures resources; do
  cp -R "$SOURCE/$dir" "$INSTALL_ROOT/$dir"
done
chmod +x "$INSTALL_ROOT/build.sh" "$INSTALL_ROOT/scripts/package_release.sh" "$INSTALL_ROOT/scripts/package_source.sh"

mkdir -p "$INSTALL_ROOT/bin"
if [[ $PREBUILT_READY -eq 1 ]]; then
  for file in VelaCUHelper VelaClick VelaPointer; do
    cp "$SOURCE/bin/$file" "$INSTALL_ROOT/bin/$file"
  done
  cp -R "$SOURCE/bin/VelaCU Status.app" "$INSTALL_ROOT/bin/VelaCU Status.app"
  chmod +x "$INSTALL_ROOT/bin/VelaCUHelper" "$INSTALL_ROOT/bin/VelaClick" "$INSTALL_ROOT/bin/VelaPointer" "$INSTALL_ROOT/bin/VelaCU Status.app/Contents/MacOS/VelaCUStatus"
fi

"$PYTHON_BIN" -m venv "$INSTALL_ROOT/.venv"
"$INSTALL_ROOT/.venv/bin/python" -m pip install --disable-pip-version-check -q -r "$INSTALL_ROOT/requirements.txt"

if [[ $PREBUILT_READY -eq 0 ]]; then
  (
    cd "$INSTALL_ROOT"
    PYTHON="$INSTALL_ROOT/.venv/bin/python" ./build.sh
  )
fi

cat > "$BIN_DIR/velacu" <<EOF
#!/bin/zsh
exec "$INSTALL_ROOT/.venv/bin/python" "$INSTALL_ROOT/velacu_cli.py" "\$@"
EOF
chmod +x "$BIN_DIR/velacu"

if [[ "$TARGET" == "codex" ]]; then
  "$BIN_DIR/velacu" setup codex
fi

"$BIN_DIR/velacu" doctor || true

rm -rf "$BACKUP"
trap - EXIT

echo
printf 'VelaCU installed at: %s\n' "$INSTALL_ROOT"
printf 'Launcher:            %s\n' "$BIN_DIR/velacu"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "Add this directory to PATH if needed: $BIN_DIR"
fi
if [[ "$TARGET" == "none" ]]; then
  echo "No agent configuration was changed. Run: $BIN_DIR/velacu setup codex"
fi
