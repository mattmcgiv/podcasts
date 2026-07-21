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
UUIDGEN_BIN="${UUIDGEN_BIN:-/usr/bin/uuidgen}"
NOTIFY_FAILURE="${IOS_NOTIFY_FAILURE:-1}"
UI_READY_CHECK="${IOS_UI_READY_CHECK:-$ROOT/ios/verify-ui-ready.sh}"
UI_STABILITY_SECONDS="${IOS_UI_STABILITY_SECONDS:-2}"
DEVICE_JSON=""
LAUNCH_JSON=""
PROCESS_JSON=""

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
  if [ -n "$LAUNCH_JSON" ]; then
    rm -f "$LAUNCH_JSON"
  fi
  if [ -n "$PROCESS_JSON" ]; then
    rm -f "$PROCESS_JSON"
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
case "$UI_STABILITY_SECONDS" in
  *[!0-9]*|'')
    echo "error: IOS_UI_STABILITY_SECONDS must be a nonnegative integer"
    exit 2
    ;;
esac

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

SOURCE_BUILD_ID="${IOS_SOURCE_BUILD_ID:-}"
if [ -z "$SOURCE_BUILD_ID" ]; then
  SOURCE_BUILD_ID="$(git -C "$ROOT" rev-parse --short=12 HEAD)"
  if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]; then
    SOURCE_BUILD_ID="${SOURCE_BUILD_ID}-dirty"
  fi
fi
case "$SOURCE_BUILD_ID" in
  *[!A-Za-z0-9._-]*|'')
    echo "error: source build ID contains unsupported characters: $SOURCE_BUILD_ID"
    exit 2
    ;;
esac
REFRESH_NONCE="${IOS_REFRESH_NONCE:-}"
if [ -z "$REFRESH_NONCE" ]; then
  REFRESH_NONCE="$("$UUIDGEN_BIN" | tr '[:upper:]' '[:lower:]')"
fi
case "$REFRESH_NONCE" in
  *[!A-Za-z0-9._-]*|'')
    echo "error: refresh nonce contains unsupported characters: $REFRESH_NONCE"
    exit 2
    ;;
esac
UI_READY_AFTER_EPOCH="${IOS_REFRESH_NOW_EPOCH:-$(date +%s)}"

XCODE_ARGS="
  -project $PROJECT
  -scheme $SCHEME
  -configuration $CONFIGURATION
  -destination $XCODE_DESTINATION
  -derivedDataPath $BUILD_DIR/DerivedData
  -allowProvisioningUpdates
  -onlyUsePackageVersionsFromResolvedFile
  -skipPackagePluginValidation
  PODS_BUILD_ID=$SOURCE_BUILD_ID
  PODS_REFRESH_NONCE=$REFRESH_NONCE
"

if [ -n "${IOS_TEAM_ID:-}" ]; then
  # Allow a launchd job to pin the Personal Team without editing the project.
  XCODE_ARGS="$XCODE_ARGS DEVELOPMENT_TEAM=$IOS_TEAM_ID"
fi

# shellcheck disable=SC2086
"$XCODEBUILD_BIN" $XCODE_ARGS build

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"
if [ ! -d "$APP_PATH" ]; then
  echo "error: expected app product not found at $APP_PATH"
  exit 1
fi

EXPECTED_BUNDLE_ID="$("$PLUTIL_BIN" -extract CFBundleIdentifier raw -o - "$APP_PATH/Info.plist" 2>/dev/null || true)"
if [ "$EXPECTED_BUNDLE_ID" != "$BUNDLE_ID" ]; then
  echo "error: built app bundle ID '$EXPECTED_BUNDLE_ID' does not match '$BUNDLE_ID'"
  exit 1
fi
EXPECTED_EXECUTABLE="$("$PLUTIL_BIN" -extract CFBundleExecutable raw -o - "$APP_PATH/Info.plist" 2>/dev/null || true)"
if [ -z "$EXPECTED_EXECUTABLE" ]; then
  echo "error: built app does not contain CFBundleExecutable"
  exit 1
fi
APP_BUNDLE_NAME="$(basename "$APP_PATH")"

EXPECTED_BUILD_ID="$("$PLUTIL_BIN" -extract PodsBuildID raw -o - "$APP_PATH/Info.plist" 2>/dev/null || true)"
if [ -z "$EXPECTED_BUILD_ID" ]; then
  echo "error: built app does not contain PodsBuildID"
  exit 1
fi
if [ "$EXPECTED_BUILD_ID" != "$SOURCE_BUILD_ID" ]; then
  echo "error: built app ID '$EXPECTED_BUILD_ID' does not match source build ID '$SOURCE_BUILD_ID'"
  exit 1
fi
EXPECTED_REFRESH_NONCE="$("$PLUTIL_BIN" -extract PodsRefreshNonce raw -o - "$APP_PATH/Info.plist" 2>/dev/null || true)"
if [ "$EXPECTED_REFRESH_NONCE" != "$REFRESH_NONCE" ]; then
  echo "error: built app refresh nonce '$EXPECTED_REFRESH_NONCE' does not match '$REFRESH_NONCE'"
  exit 1
fi

echo "Installing $APP_PATH to $DEVICE_ID"
"$XCRUN_BIN" devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
echo "Install finished. Existing app data should remain because this script does not uninstall the app."

echo "Verifying that $BUNDLE_ID launches on $DEVICE_ID"
LAUNCH_JSON="$(mktemp "${TMPDIR:-/tmp}/pods-refresh-launch.XXXXXX")"
"$XCRUN_BIN" devicectl device process launch \
  --device "$DEVICE_ID" \
  --terminate-existing \
  --json-output "$LAUNCH_JSON" \
  --quiet \
  "$BUNDLE_ID"
LAUNCHED_PID="$("$PLUTIL_BIN" -extract result.process.processIdentifier raw -o - "$LAUNCH_JSON" 2>/dev/null || true)"
case "$LAUNCHED_PID" in
  *[!0-9]*|'')
    echo "error: launch did not return a valid process identifier"
    exit 1
    ;;
esac
LAUNCHED_EXECUTABLE="$("$PLUTIL_BIN" -extract result.process.executable raw -o - "$LAUNCH_JSON" 2>/dev/null || true)"
case "$LAUNCHED_EXECUTABLE" in
  *"/$APP_BUNDLE_NAME/$EXPECTED_EXECUTABLE") ;;
  *)
    echo "error: launched executable '$LAUNCHED_EXECUTABLE' is not the installed $APP_BUNDLE_NAME/$EXPECTED_EXECUTABLE"
    exit 1
    ;;
esac

echo "Waiting for $BUNDLE_ID UI readiness for build $EXPECTED_BUILD_ID"
IOS_DEVICE_ID="$DEVICE_ID" \
IOS_BUNDLE_ID="$BUNDLE_ID" \
IOS_UI_READY_AFTER_EPOCH="$UI_READY_AFTER_EPOCH" \
IOS_EXPECTED_BUILD_ID="$EXPECTED_BUILD_ID" \
IOS_EXPECTED_REFRESH_NONCE="$EXPECTED_REFRESH_NONCE" \
XCRUN_BIN="$XCRUN_BIN" \
  "$UI_READY_CHECK"

if [ "$UI_STABILITY_SECONDS" -gt 0 ]; then
  sleep "$UI_STABILITY_SECONDS"
fi

echo "Rechecking UI readiness after ${UI_STABILITY_SECONDS}s stability window"
IOS_DEVICE_ID="$DEVICE_ID" \
IOS_BUNDLE_ID="$BUNDLE_ID" \
IOS_UI_READY_AFTER_EPOCH="$UI_READY_AFTER_EPOCH" \
IOS_EXPECTED_BUILD_ID="$EXPECTED_BUILD_ID" \
IOS_EXPECTED_REFRESH_NONCE="$EXPECTED_REFRESH_NONCE" \
XCRUN_BIN="$XCRUN_BIN" \
  "$UI_READY_CHECK"

PROCESS_JSON="$(mktemp "${TMPDIR:-/tmp}/pods-refresh-processes.XXXXXX")"
"$XCRUN_BIN" devicectl device info processes \
  --device "$DEVICE_ID" \
  --timeout 15 \
  --json-output "$PROCESS_JSON" \
  --quiet
PROCESS_COUNT="$("$PLUTIL_BIN" -extract result.runningProcesses raw -o - "$PROCESS_JSON" 2>/dev/null || true)"
case "$PROCESS_COUNT" in
  *[!0-9]*|'')
    echo "error: could not read the running process list"
    exit 1
    ;;
esac
PROCESS_MATCHED=0
PROCESS_INDEX=0
while [ "$PROCESS_INDEX" -lt "$PROCESS_COUNT" ]; do
  CANDIDATE_PID="$("$PLUTIL_BIN" -extract "result.runningProcesses.$PROCESS_INDEX.processIdentifier" raw -o - "$PROCESS_JSON" 2>/dev/null || true)"
  if [ "$CANDIDATE_PID" = "$LAUNCHED_PID" ]; then
    CANDIDATE_EXECUTABLE="$("$PLUTIL_BIN" -extract "result.runningProcesses.$PROCESS_INDEX.executable" raw -o - "$PROCESS_JSON" 2>/dev/null || true)"
    if [ "$CANDIDATE_EXECUTABLE" = "$LAUNCHED_EXECUTABLE" ]; then
      PROCESS_MATCHED=1
      break
    fi
  fi
  PROCESS_INDEX=$((PROCESS_INDEX + 1))
done
if [ "$PROCESS_MATCHED" != "1" ]; then
  echo "error: launched Pods process $LAUNCHED_PID is no longer running"
  exit 1
fi

mkdir -p "$(dirname "$SUCCESS_FILE")"
SUCCESS_TMP="${SUCCESS_FILE}.tmp.$$"
printf '%s\n' "${IOS_REFRESH_NOW_EPOCH:-$(date +%s)}" > "$SUCCESS_TMP"
mv "$SUCCESS_TMP" "$SUCCESS_FILE"
