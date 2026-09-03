#!/bin/sh
set -eu
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
