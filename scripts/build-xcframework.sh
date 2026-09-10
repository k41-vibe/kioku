#!/usr/bin/env bash
# Cross-compile the Rust bridge (rslib + 4 C functions) for iOS and package it
# as dist/core/AnkiRustLib.xcframework (static library + module map).
#
# Env:
#   WITH_SIM=1                    also build aarch64-apple-ios-sim (needed for simulator tests)
#   IPHONEOS_DEPLOYMENT_TARGET    default 17.0
#   PROTOC                        path to protoc (default: from PATH)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BR="$ROOT/bridge"
DIST="$ROOT/dist/core"
OUT="$DIST/AnkiRustLib.xcframework"

export PROTOC="${PROTOC:-$(command -v protoc)}"
# rslib's build scripts hand the descriptor set to each other through this path.
# Newer cargo build-dir layouts break the implicit OUT_DIR/../../ default, so pin it.
export DESCRIPTORS_BIN="${DESCRIPTORS_BIN:-$BR/target/anki_descriptors.bin}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
WITH_SIM="${WITH_SIM:-1}"

# Use anki's own lockfile so we build the exact dependency versions anki tests.
if [ ! -f "$BR/Cargo.lock" ]; then
  cp "$ROOT/anki/Cargo.lock" "$BR/Cargo.lock"
fi

echo "==> protoc: $PROTOC ($("$PROTOC" --version))"
echo "==> rustc:  $(rustc --version)"
echo "==> iOS deployment target: $IPHONEOS_DEPLOYMENT_TARGET"

TARGETS=(aarch64-apple-ios)
if [ "$WITH_SIM" = "1" ]; then
  TARGETS+=(aarch64-apple-ios-sim)
fi

ARGS=()
for T in "${TARGETS[@]}"; do
  echo "==> cargo build --release --target $T"
  cargo build --manifest-path "$BR/Cargo.toml" --release --target "$T"
  LIB="$BR/target/$T/release/libanki_bridge_ios.a"
  [ -f "$LIB" ] || { echo "ERROR: $LIB not produced"; exit 1; }
  echo "    $(du -h "$LIB" | cut -f1)  $LIB"
  ARGS+=(-library "$LIB" -headers "$BR/include")
done

[ -f "$DESCRIPTORS_BIN" ] || { echo "ERROR: descriptor set not found at $DESCRIPTORS_BIN"; exit 1; }

rm -rf "$OUT"
mkdir -p "$DIST"
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT"

for H in "$OUT"/*/Headers; do
  cat > "$H/module.modulemap" <<'MODULEMAP'
module AnkiRustLib {
    header "anki_bridge.h"
    export *
}
MODULEMAP
done

cp "$DESCRIPTORS_BIN" "$DIST/anki_descriptors.bin"
git -C "$ROOT/anki" rev-parse HEAD > "$DIST/anki_commit.txt"
echo "==> XCFramework ready: $OUT"
find "$OUT" -type f | sed "s|$ROOT/||"
