#!/usr/bin/env bash
# Generate Swift protobuf types for all anki .proto files plus AnkiRPC.swift
# (service/method dispatch indices) into dist/core/AnkiProtoSwift/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist/core"
GEN="$DIST/AnkiProtoSwift"
PROTO_DIR="$ROOT/anki/proto"
DESCRIPTORS="${DESCRIPTORS_BIN:-$DIST/anki_descriptors.bin}"

command -v protoc >/dev/null || { echo "protoc missing (brew install protobuf)"; exit 1; }
command -v protoc-gen-swift >/dev/null || { echo "protoc-gen-swift missing (brew install swift-protobuf)"; exit 1; }
[ -f "$DESCRIPTORS" ] || { echo "descriptor set missing at $DESCRIPTORS (run build-xcframework.sh first)"; exit 1; }

rm -rf "$GEN"
mkdir -p "$GEN"

echo "==> protoc $(protoc --version) / protoc-gen-swift $(protoc-gen-swift --version 2>/dev/null || echo '?')"
protoc \
  --proto_path="$PROTO_DIR" \
  --swift_out="$GEN" \
  --swift_opt=Visibility=Internal \
  --swift_opt=FileNaming=DropPath \
  "$PROTO_DIR"/anki/*.proto

ANKI_SHA="$(git -C "$ROOT/anki" rev-parse HEAD)"
DG="$ROOT/tools/dispatch-gen"
if [ ! -f "$DG/Cargo.lock" ]; then
  cp "$ROOT/anki/Cargo.lock" "$DG/Cargo.lock"
fi
echo "==> dispatch-gen"
cargo run --quiet --release --manifest-path "$DG/Cargo.toml" -- "$DESCRIPTORS" "$ANKI_SHA" > "$GEN/AnkiRPC.swift"

protoc-gen-swift --version > "$DIST/protoc_gen_swift_version.txt" 2>&1 || true
echo "==> $(ls "$GEN"/*.swift | wc -l | tr -d ' ') Swift files in $GEN"
grep -c "static let" "$GEN/AnkiRPC.swift" | sed 's/^/    AnkiRPC constants: /'
