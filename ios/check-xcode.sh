#!/bin/sh
# DEPRECATED as of 1 October 2026. Do not review, extend, or append to this script.
# See ios/DEPRECATED.md.
# Verify the host has the Xcode pieces needed for iPhone install/refresh.
set -eu
echo "warning: deprecated as of 1 October 2026; do not extend this iPhone app/signing/install tooling. See ios/DEPRECATED.md." >&2

fail() {
  echo "error: $*" >&2
  exit 1
}

if ! command -v xcodebuild >/dev/null 2>&1; then
  fail "xcodebuild is not on PATH. Install full Xcode first."
fi

DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
case "$DEVELOPER_DIR" in
  *"/Xcode.app/"*|*"/Xcode-beta.app/"*) ;;
  *)
    fail "active developer directory is '$DEVELOPER_DIR', not full Xcode. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    ;;
esac

xcodebuild -version

if ! xcrun --find devicectl >/dev/null 2>&1; then
  fail "devicectl is unavailable. Open Xcode once and install required iOS platform components."
fi

echo "devicectl: $(xcrun --find devicectl)"
echo "Xcode is available. Pair the iPhone in Xcode and enable network installs before using refresh-device.sh."
