#!/bin/sh
# DEPRECATED as of 1 October 2026. Do not review, extend, or append to this script.
# See ios/DEPRECATED.md.
# Install the expiry-aware Pods signing refresh launchd job.
set -eu
echo "warning: deprecated as of 1 October 2026; do not extend this iPhone app/signing/install tooling. See ios/DEPRECATED.md." >&2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_ID="${IOS_DEVICE_ID:-}"
XCODE_DESTINATION="${IOS_XCODE_DESTINATION:-}"
TEAM_ID="${IOS_TEAM_ID:-}"
CHECK_INTERVAL_SECONDS="${IOS_REFRESH_CHECK_INTERVAL_SECONDS:-900}"
SUCCESS_INTERVAL_SECONDS="${IOS_REFRESH_SUCCESS_INTERVAL_SECONDS:-172800}"
PROFILE_RENEWAL_WINDOW_SECONDS="${IOS_PROFILE_RENEWAL_WINDOW_SECONDS:-259200}"
PROFILE_WARNING_SECONDS="${IOS_PROFILE_WARNING_SECONDS:-172800}"
PROFILE_CRITICAL_SECONDS="${IOS_PROFILE_CRITICAL_SECONDS:-43200}"
PLIST_OUT="$HOME/Library/LaunchAgents/dev.mcgiv.pods.refresh.plist"
LABEL="dev.mcgiv.pods.refresh"
DOMAIN="gui/$(id -u)"

if [ -z "$DEVICE_ID" ]; then
  echo "error: IOS_DEVICE_ID is required. Find it with: xcrun devicectl list devices" >&2
  exit 2
fi
if [ -z "$XCODE_DESTINATION" ]; then
  XCODE_DESTINATION="platform=iOS,id=$DEVICE_ID"
fi
for TIMING_VALUE in \
  "$CHECK_INTERVAL_SECONDS" \
  "$SUCCESS_INTERVAL_SECONDS" \
  "$PROFILE_RENEWAL_WINDOW_SECONDS" \
  "$PROFILE_WARNING_SECONDS" \
  "$PROFILE_CRITICAL_SECONDS"; do
  case "$TIMING_VALUE" in
    ''|*[!0-9]*)
      echo "error: refresh timing values must be positive integers" >&2
      exit 2
      ;;
  esac
  if [ "$TIMING_VALUE" -lt 60 ]; then
    echo "error: refresh timing values must be at least 60 seconds" >&2
    exit 2
  fi
done
if [ "$PROFILE_CRITICAL_SECONDS" -ge "$PROFILE_WARNING_SECONDS" ] ||
   [ "$PROFILE_WARNING_SECONDS" -ge "$PROFILE_RENEWAL_WINDOW_SECONDS" ]; then
  echo "error: profile timing must satisfy critical < warning < renewal window" >&2
  exit 2
fi

mkdir -p "$(dirname "$PLIST_OUT")"
mkdir -p "$ROOT/ios/build"
sed \
  -e "s#__ROOT__#$ROOT#g" \
  -e "s#__DEVICE_ID__#$DEVICE_ID#g" \
  -e "s#__XCODE_DESTINATION__#$XCODE_DESTINATION#g" \
  -e "s#__TEAM_ID__#$TEAM_ID#g" \
  -e "s#__CHECK_INTERVAL_SECONDS__#$CHECK_INTERVAL_SECONDS#g" \
  -e "s#__SUCCESS_INTERVAL_SECONDS__#$SUCCESS_INTERVAL_SECONDS#g" \
  -e "s#__PROFILE_RENEWAL_WINDOW_SECONDS__#$PROFILE_RENEWAL_WINDOW_SECONDS#g" \
  -e "s#__PROFILE_WARNING_SECONDS__#$PROFILE_WARNING_SECONDS#g" \
  -e "s#__PROFILE_CRITICAL_SECONDS__#$PROFILE_CRITICAL_SECONDS#g" \
  "$ROOT/ios/dev.mcgiv.pods.refresh.plist.template" > "$PLIST_OUT"

launchctl bootout "$DOMAIN" "$PLIST_OUT" >/dev/null 2>&1 || true
launchctl bootstrap "$DOMAIN" "$PLIST_OUT"
launchctl enable "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
echo "Installed launchd job at $PLIST_OUT"
echo "It checks every ${CHECK_INTERVAL_SECONDS}s, refreshes after ${SUCCESS_INTERVAL_SECONDS}s,"
echo "forces a fresh profile inside ${PROFILE_RENEWAL_WINDOW_SECONDS}s of expiration, and retries while the phone is unavailable."
echo "Install logs: ~/Library/Logs/Pods/ios-refresh.log"
