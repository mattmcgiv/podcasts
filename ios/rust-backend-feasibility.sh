#!/bin/sh
# Probe whether the Rust backend can be built for iOS without running host Rust.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Policy: this script must not run host cargo/rustc."

if command -v cargo >/dev/null 2>&1 || command -v rustc >/dev/null 2>&1; then
  echo "Host Rust is installed, but intentionally unused."
fi

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  echo "No usable iPhoneOS SDK found via xcrun. Install/select full Xcode first."
  exit 1
fi

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "Host iPhoneOS SDK: $SDK_PATH"

if ! container inspect pods-dev >/dev/null 2>&1; then
  "$ROOT/dev/up.sh"
fi

container exec pods-dev sh -lc '
  set -eu
  echo "Guest uname: $(uname -a)"
  if [ "$(uname -s)" != "Linux" ]; then
    echo "Unexpected guest OS; expected Linux dev container."
    exit 1
  fi
  rustup target list --installed | grep -q "^aarch64-apple-ios$" || {
    echo "Guest Rust target aarch64-apple-ios is not installed."
    exit 1
  }
  if [ ! -d /Applications/Xcode.app ] && [ ! -d /opt/ios-sdk ]; then
    echo "Guest has no Apple iOS SDK. The current pods-dev Linux image cannot link an iOS Rust static library."
    exit 2
  fi
'

echo "Rust iOS backend build path still needs a guest-visible Apple SDK/linker configuration."
