#!/bin/sh
# DEPRECATED as of 1 October 2026. Do not review, extend, or append to this script.
# See ios/DEPRECATED.md.
set -eu
echo "warning: deprecated as of 1 October 2026; do not extend this iPhone app/signing/install tooling. See ios/DEPRECATED.md." >&2
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
case "${PLATFORM_NAME:-iphonesimulator}" in
  iphoneos)
    TARGET=aarch64-apple-ios
    ;;
  *)
    TARGET=aarch64-apple-ios-sim
    ;;
esac
cargo build --release --target "$TARGET"
echo "built $ROOT/target/$TARGET/release/libpods_backend.a"
