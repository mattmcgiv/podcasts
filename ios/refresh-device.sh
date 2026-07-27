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
PROFILE_STATE_FILE="${IOS_REFRESH_PROFILE_STATE_FILE:-$HOME/Library/Application Support/PodsRefresh/profile-state}"
XCODEBUILD_BIN="${XCODEBUILD_BIN:-xcodebuild}"
XCRUN_BIN="${XCRUN_BIN:-xcrun}"
PLUTIL_BIN="${PLUTIL_BIN:-/usr/bin/plutil}"
UUIDGEN_BIN="${UUIDGEN_BIN:-/usr/bin/uuidgen}"
NOTIFY_FAILURE="${IOS_NOTIFY_FAILURE:-1}"
FORCE_PROFILE_RENEWAL="${IOS_FORCE_PROFILE_RENEWAL:-0}"
PROFILE_FRESH_VALIDITY_SECONDS="${IOS_PROFILE_FRESH_VALIDITY_SECONDS:-518400}"
PROFILE_MINIMUM_VALIDITY_SECONDS="${IOS_PROFILE_MINIMUM_VALIDITY_SECONDS:-86400}"
PROFILE_METADATA_BIN="${IOS_PROFILE_METADATA_BIN:-$ROOT/ios/profile-metadata.sh}"
PROFILE_CACHE_DIRS="${IOS_PROFILE_CACHE_DIRS:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles:$HOME/Library/MobileDevice/Provisioning Profiles}"
PROFILE_BACKUP_DIR="${IOS_PROFILE_BACKUP_DIR:-$HOME/Library/Application Support/PodsRefresh/profile-backups}"
SIGNING_REMINDER_BIN="${IOS_SIGNING_REMINDER_BIN:-$ROOT/ios/update-signing-reminders.sh}"
UI_READY_CHECK="${IOS_UI_READY_CHECK:-$ROOT/ios/verify-ui-ready.sh}"
UI_STABILITY_SECONDS="${IOS_UI_STABILITY_SECONDS:-2}"
DEVICE_JSON=""
LAUNCH_JSON=""
PROCESS_JSON=""
PROFILE_METADATA_FILE=""

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
  if [ -n "$PROFILE_METADATA_FILE" ]; then
    rm -f "$PROFILE_METADATA_FILE"
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

if [ "$FORCE_PROFILE_RENEWAL" = "1" ]; then
  if [ -z "${IOS_TEAM_ID:-}" ]; then
    echo "error: IOS_TEAM_ID is required for forced profile renewal"
    exit 2
  fi
  mkdir -p "$PROFILE_BACKUP_DIR"
  OLD_IFS="$IFS"
  IFS=:
  set -- $PROFILE_CACHE_DIRS
  IFS="$OLD_IFS"
  for PROFILE_CACHE_DIR in "$@"; do
    [ -d "$PROFILE_CACHE_DIR" ] || continue
    for CACHED_PROFILE in "$PROFILE_CACHE_DIR"/*.mobileprovision "$PROFILE_CACHE_DIR"/*.provisionprofile; do
      [ -f "$CACHED_PROFILE" ] || continue
      CACHED_METADATA="$(mktemp "${TMPDIR:-/tmp}/pods-cached-profile.XXXXXX")"
      if "$PROFILE_METADATA_BIN" "$CACHED_PROFILE" > "$CACHED_METADATA" 2>/dev/null; then
        CACHED_APPLICATION_IDENTIFIER="$(sed -n 's/^application_identifier=//p' "$CACHED_METADATA" | sed -n '1p')"
        CACHED_EXPIRATION_EPOCH="$(sed -n 's/^profile_expiration_epoch=//p' "$CACHED_METADATA" | sed -n '1p')"
        if [ "$CACHED_APPLICATION_IDENTIFIER" = "${IOS_TEAM_ID}.${BUNDLE_ID}" ]; then
          case "$CACHED_EXPIRATION_EPOCH" in
            ''|*[!0-9]*)
              ;;
            *)
              CACHED_VALIDITY_SECONDS=$((CACHED_EXPIRATION_EPOCH - UI_READY_AFTER_EPOCH))
              if [ "$CACHED_VALIDITY_SECONDS" -lt "$PROFILE_FRESH_VALIDITY_SECONDS" ]; then
                BACKUP_PATH="$PROFILE_BACKUP_DIR/$(basename "$CACHED_PROFILE")"
                if [ -e "$BACKUP_PATH" ]; then
                  BACKUP_PATH="${BACKUP_PATH}.$UI_READY_AFTER_EPOCH"
                fi
                echo "Archiving expiring Pods profile $(basename "$CACHED_PROFILE") before renewal"
                mv "$CACHED_PROFILE" "$BACKUP_PATH"
              fi
              ;;
          esac
        fi
      fi
      rm -f "$CACHED_METADATA"
    done
  done
fi

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

PROFILE_PATH="$APP_PATH/embedded.mobileprovision"
if [ ! -f "$PROFILE_PATH" ]; then
  echo "error: signed build does not contain embedded.mobileprovision"
  exit 1
fi
PROFILE_METADATA_FILE="$(mktemp "${TMPDIR:-/tmp}/pods-profile-metadata.XXXXXX")"
"$PROFILE_METADATA_BIN" "$PROFILE_PATH" > "$PROFILE_METADATA_FILE"
BUILT_PROFILE_UUID="$(sed -n 's/^profile_uuid=//p' "$PROFILE_METADATA_FILE" | sed -n '1p')"
BUILT_PROFILE_CREATION_EPOCH="$(sed -n 's/^profile_creation_epoch=//p' "$PROFILE_METADATA_FILE" | sed -n '1p')"
BUILT_PROFILE_EXPIRATION_EPOCH="$(sed -n 's/^profile_expiration_epoch=//p' "$PROFILE_METADATA_FILE" | sed -n '1p')"
BUILT_APPLICATION_IDENTIFIER="$(sed -n 's/^application_identifier=//p' "$PROFILE_METADATA_FILE" | sed -n '1p')"
if [ -n "${IOS_TEAM_ID:-}" ]; then
  if [ "$BUILT_APPLICATION_IDENTIFIER" != "${IOS_TEAM_ID}.${BUNDLE_ID}" ]; then
    echo "error: signed profile application identifier '$BUILT_APPLICATION_IDENTIFIER' does not match '${IOS_TEAM_ID}.${BUNDLE_ID}'"
    exit 1
  fi
else
  case "$BUILT_APPLICATION_IDENTIFIER" in
    *".$BUNDLE_ID") ;;
    *)
      echo "error: signed profile application identifier '$BUILT_APPLICATION_IDENTIFIER' does not match '$BUNDLE_ID'"
      exit 1
      ;;
  esac
fi
case "$BUILT_PROFILE_UUID" in
  *[!A-Za-z0-9._-]*|'')
    echo "error: signed profile has an invalid UUID"
    exit 1
    ;;
esac
case "$BUILT_PROFILE_CREATION_EPOCH:$BUILT_PROFILE_EXPIRATION_EPOCH" in
  *[!0-9:]*|:*|*:)
    echo "error: signed profile has invalid dates"
    exit 1
    ;;
esac
PROFILE_VALIDITY_SECONDS=$((BUILT_PROFILE_EXPIRATION_EPOCH - UI_READY_AFTER_EPOCH))
REQUIRED_PROFILE_VALIDITY_SECONDS="$PROFILE_MINIMUM_VALIDITY_SECONDS"
if [ "$FORCE_PROFILE_RENEWAL" = "1" ]; then
  REQUIRED_PROFILE_VALIDITY_SECONDS="$PROFILE_FRESH_VALIDITY_SECONDS"
fi
if [ "$PROFILE_VALIDITY_SECONDS" -lt "$REQUIRED_PROFILE_VALIDITY_SECONDS" ]; then
  if [ "$FORCE_PROFILE_RENEWAL" = "1" ]; then
    echo "error: renewed profile is not fresh enough (${PROFILE_VALIDITY_SECONDS}s remaining)"
  else
    echo "error: signed profile expires too soon (${PROFILE_VALIDITY_SECONDS}s remaining)"
  fi
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

mkdir -p "$(dirname "$SUCCESS_FILE")" "$(dirname "$PROFILE_STATE_FILE")"
PROFILE_STATE_TMP="${PROFILE_STATE_FILE}.tmp.$$"
{
  printf 'profile_uuid=%s\n' "$BUILT_PROFILE_UUID"
  printf 'profile_creation_epoch=%s\n' "$BUILT_PROFILE_CREATION_EPOCH"
  printf 'profile_expiration_epoch=%s\n' "$BUILT_PROFILE_EXPIRATION_EPOCH"
  printf 'last_success_epoch=%s\n' "${IOS_REFRESH_NOW_EPOCH:-$(date +%s)}"
} > "$PROFILE_STATE_TMP"
SUCCESS_TMP="${SUCCESS_FILE}.tmp.$$"
printf '%s\n' "${IOS_REFRESH_NOW_EPOCH:-$(date +%s)}" > "$SUCCESS_TMP"
mv "$PROFILE_STATE_TMP" "$PROFILE_STATE_FILE"
mv "$SUCCESS_TMP" "$SUCCESS_FILE"
if ! "$SIGNING_REMINDER_BIN" "$BUILT_PROFILE_UUID" "$BUILT_PROFILE_EXPIRATION_EPOCH"; then
  echo "warning: refresh succeeded, but signing safety reminders could not be updated"
fi
