#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CUA_COMMIT="${VELACU_CUA_COMMIT:-2fe1c3250cc84574f376aa314a077a33ef48d1dd}"
SOURCE_ROOT="${VELACU_BUILD_DIR:-$ROOT/.build/cua-source}"
CARGO_TARGET_DIR="${VELACU_CARGO_TARGET_DIR:-$ROOT/.build/cua-target}"
REPO="$SOURCE_ROOT/repo"
RUST_ROOT="$REPO/libs/cua-driver/rust"
OVERRIDES="$ROOT/third_party/cua-driver-overrides/crates/platform-macos/src"
OUT="$ROOT/bin/velacu-cua-driver"

command -v git >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 2; }
command -v cargo >/dev/null 2>&1 || {
  echo "error: Rust/cargo is required to build the modified Cua driver." >&2
  echo "Install Rust from https://rustup.rs, then rerun ./build.sh." >&2
  exit 2
}

# Keep the disposable source checkout separate from Cargo's target directory.
# This avoids a cleanup race if a previous compiler process is still unwinding.
rm -rf "$SOURCE_ROOT"
mkdir -p "$SOURCE_ROOT" "$CARGO_TARGET_DIR"

if [[ -n "${VELACU_CUA_SOURCE:-}" ]]; then
  SOURCE="${VELACU_CUA_SOURCE:A}"
  git -C "$SOURCE" cat-file -e "$CUA_COMMIT^{commit}"
  mkdir -p "$REPO"
  git -C "$SOURCE" archive "$CUA_COMMIT" libs/cua-driver/rust | tar -x -C "$REPO"
else
  git init -q "$REPO"
  git -C "$REPO" remote add origin https://github.com/trycua/cua.git
  git -C "$REPO" config core.sparseCheckout true
  mkdir -p "$REPO/.git/info"
  printf '/libs/cua-driver/rust/\n' > "$REPO/.git/info/sparse-checkout"
  git -C "$REPO" fetch -q --depth 1 origin "$CUA_COMMIT"
  git -C "$REPO" checkout -q --detach FETCH_HEAD
fi

INPUT="$RUST_ROOT/crates/platform-macos/src/input"
TOOLS="$RUST_ROOT/crates/platform-macos/src/tools"
test -d "$INPUT"
test -d "$TOOLS"
cp "$OVERRIDES/input/mouse.rs" "$INPUT/mouse.rs"
cp "$OVERRIDES/tools/mod.rs" "$TOOLS/mod.rs"
cp "$OVERRIDES/tools/velacu_click.rs" "$TOOLS/velacu_click.rs"
rm -f "$TOOLS/lightcu_click.rs"

(
  cd "$RUST_ROOT"
  export CARGO_TARGET_DIR
  if [[ -n "${HOME:-}" ]]; then
    export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=$HOME=/Users/USER"
  fi
  cargo build --release -p cua-driver
)

mkdir -p "$ROOT/bin"
TMP="$ROOT/bin/.velacu-cua-driver.$RANDOM"
cp "$CARGO_TARGET_DIR/release/cua-driver" "$TMP"
chmod +x "$TMP"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$TMP"
fi

TOOLS_OUTPUT="$("$TMP" list-tools)"
if [[ "$TOOLS_OUTPUT" != *"click: Pure XY background click for VelaCU"* ]]; then
  rm -f "$TMP"
  echo "error: rebuilt Cua driver does not expose the VelaCU pixel-click tool" >&2
  exit 1
fi

mv -f "$TMP" "$OUT"
shasum -a 256 \
  "$OVERRIDES/input/mouse.rs" \
  "$OVERRIDES/tools/mod.rs" \
  "$OVERRIDES/tools/velacu_click.rs" \
  > "$ROOT/bin/velacu-cua-driver.source.sha256"

echo "Built modified Cua driver from pinned upstream commit $CUA_COMMIT"
echo "Output: $OUT"
