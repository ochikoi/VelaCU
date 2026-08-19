#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CUA_COMMIT="${VELACU_CUA_COMMIT:-2fe1c3250cc84574f376aa314a077a33ef48d1dd}"
BUILD_ROOT="${VELACU_BUILD_DIR:-$ROOT/.build/cua}"
REPO="$BUILD_ROOT/repo"
RUST_ROOT="$REPO/libs/cua-driver/rust"
OVERRIDES="$ROOT/third_party/cua-driver-overrides/crates/platform-macos/src/tools"
OUT="$ROOT/bin/velacu-cua-driver"

command -v git >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 2; }
command -v cargo >/dev/null 2>&1 || {
  echo "error: Rust/cargo is required to build the modified Cua driver." >&2
  echo "Install Rust from https://rustup.rs, then rerun ./build.sh." >&2
  exit 2
}

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

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

TOOLS="$RUST_ROOT/crates/platform-macos/src/tools"
test -d "$TOOLS"
cp "$OVERRIDES/mod.rs" "$TOOLS/mod.rs"
cp "$OVERRIDES/velacu_click.rs" "$TOOLS/velacu_click.rs"
rm -f "$TOOLS/lightcu_click.rs"

(
  cd "$RUST_ROOT"
  cargo build --release -p cua-driver
)

mkdir -p "$ROOT/bin"
cp "$RUST_ROOT/target/release/cua-driver" "$OUT"
chmod +x "$OUT"

echo "Built modified Cua driver from pinned upstream commit $CUA_COMMIT"
echo "Output: $OUT"
