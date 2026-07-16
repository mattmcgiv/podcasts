#!/bin/sh
# Build/sign Pods and install it over the existing iPhone app.
# This must never uninstall the app; reinstall-over-existing preserves app data.
set -eu
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$HOME/Library/Logs/Pods"
LOG_FILE="$LOG_DIR/ios-refresh.log"
PROJECT="$ROOT/ios/Pods.xcodeproj"
SCHEME="${IOS_SCHEME:-Pods}"
CONFIGURATION="${IOS_CONFIGURATION:-Debug}"
BUNDLE_ID="${IOS_BUNDLE_ID:-dev.mcgiv.pods}"
DEVICE_ID="${IOS_DEVICE_ID:-}"
XCODE_DESTINATION="${IOS_XCODE_DESTINATION:-}"
BUILD_DIR="${IOS_BUILD_DIR:-$ROOT/ios/build}"
SKIP_WEB_ASSETS="${IOS_SKIP_WEB_ASSETS:-0}"
SUCCESS_FILE="${IOS_REFRESH_SUCCESS_FILE:-$HOME/Library/Application Support/PodsRefresh/last-success-epoch}"
XCODEBUILD_BIN="${XCODEBUILD_BIN:-xcodebuild}"
XCRUN_BIN="${XCRUN_BIN:-xcrun}"
PLUTIL_BIN="${PLUTIL_BIN:-/usr/bin/plutil}"
NOTIFY_FAILURE="${IOS_NOTIFY_FAILURE:-1}"
DEVICE_JSON=""

mkdir -p "$LOG_DIR" "$BUILD_DIR"
touch "$LOG_FILE"

notify_failure() {
  if [ "$NOTIFY_FAILURE" != "1" ]; then
    return
  fi
  osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
display notification "Pods iPhone reinstall failed. See ~/Library/Logs/Pods/ios-refresh.log." with title "Pods Refresh Failed"
APPLESCRIPT
}

finish() {
  status=$?
  if [ -n "$DEVICE_JSON" ]; then
    rm -f "$DEVICE_JSON"
  fi
  if [ "$status" -ne 0 ]; then
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] refresh failed with exit $status"
    notify_failure
  else
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] refresh succeeded"
  fi
}
trap finish EXIT

exec >>"$LOG_FILE" 2>&1

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] starting Pods iOS refresh"

if [ -z "$DEVICE_ID" ]; then
  echo "error: IOS_DEVICE_ID is required. Find it with: xcrun devicectl list devices"
  exit 2
fi
if [ -z "$XCODE_DESTINATION" ]; then
  XCODE_DESTINATION="platform=iOS,id=$DEVICE_ID"
fi

"$ROOT/ios/check-xcode.sh"

if [ "$SKIP_WEB_ASSETS" != "1" ]; then
  "$ROOT/ios/prepare-web-assets.sh"
fi

DEVICE_JSON="$(mktemp "${TMPDIR:-/tmp}/pods-refresh-device.XXXXXX")"
if ! "$XCRUN_BIN" devicectl device info details \
  --device "$DEVICE_ID" \
  --timeout 15 \
  --json-output "$DEVICE_JSON" \
  --quiet; then
  echo "error: could not check whether $DEVICE_ID is connected"
  exit 75
fi

TUNNEL_STATE="$("$PLUTIL_BIN" -extract result.connectionProperties.tunnelState raw -o - "$DEVICE_JSON" 2>/dev/null || true)"
if [ "$TUNNEL_STATE" != "connected" ]; then
  echo "error: $DEVICE_ID is not connected; refusing to sign until it can be installed"
  exit 75
fi

XCODE_ARGS="
  -project $PROJECT
  -scheme $SCHEME
  -configuration $CONFIGURATION
  -destination $XCODE_DESTINATION
  -derivedDataPath $BUILD_DIR/DerivedData
  -allowProvisioningUpdates
"

if [ -n "${IOS_TEAM_ID:-}" ]; then
  # Allow a launchd job to pin the Personal Team without editing the project.
  XCODE_ARGS="$XCODE_ARGS DEVELOPMENT_TEAM=$IOS_TEAM_ID"
fi

# shellcheck disable=SC2086
"$XCODEBUILD_BIN" $XCODE_ARGS build

APP_PATH="$(find "$BUILD_DIR/DerivedData/Build/Products/${CONFIGURATION}-iphoneos" -maxdepth 1 -name "*.app" -type d | head -n 1)"
if [ -z "$APP_PATH" ]; then
  echo "error: built .app not found"
  exit 1
fi

echo "Installing $APP_PATH to $DEVICE_ID"
"$XCRUN_BIN" devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
echo "Install finished. Existing app data should remain because this script does not uninstall the app."

echo "Verifying that $BUNDLE_ID launches on $DEVICE_ID"
"$XCRUN_BIN" devicectl device process launch \
  --device "$DEVICE_ID" \
  --terminate-existing \
  "$BUNDLE_ID"

mkdir -p "$(dirname "$SUCCESS_FILE")"
SUCCESS_TMP="${SUCCESS_FILE}.tmp.$$"
printf '%s\n' "${IOS_REFRESH_NOW_EPOCH:-$(date +%s)}" > "$SUCCESS_TMP"
mv "$SUCCESS_TMP" "$SUCCESS_FILE"
