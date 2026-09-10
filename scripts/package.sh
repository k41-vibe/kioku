#!/usr/bin/env bash
# Zip the core artifacts and write dist/core/manifest.json.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist/core"
cd "$DIST"

rm -f AnkiRustLib.xcframework.zip AnkiProtoSwift.zip manifest.json
zip -qry AnkiRustLib.xcframework.zip AnkiRustLib.xcframework
zip -qry AnkiProtoSwift.zip AnkiProtoSwift

sha() { shasum -a 256 "$1" | awk '{print $1}'; }
cat > manifest.json <<EOF
{
  "anki_commit": "$(cat anki_commit.txt)",
  "rustc": "$(rustc --version)",
  "protoc": "$(protoc --version)",
  "protoc_gen_swift": "$(cat protoc_gen_swift_version.txt 2>/dev/null || echo unknown)",
  "ios_deployment_target": "${IPHONEOS_DEPLOYMENT_TARGET:-17.0}",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "sha256": {
    "AnkiRustLib.xcframework.zip": "$(sha AnkiRustLib.xcframework.zip)",
    "AnkiProtoSwift.zip": "$(sha AnkiProtoSwift.zip)"
  }
}
EOF
cat manifest.json
ls -lh *.zip
