#!/bin/sh
# launchd entrypoint for unattended Pods refresh checks.
set -eu
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_ID="${IOS_DEVICE_ID:-}"
REFRESH_SCRIPT="${IOS_REFRESH_SCRIPT:-$ROOT/ios/refresh-device.sh}"
SUCCESS_FILE="${IOS_REFRESH_SUCCESS_FILE:-$HOME/Library/Application Support/PodsRefresh/last-success-epoch}"
SUCCESS_INTERVAL_SECONDS="${IOS_REFRESH_SUCCESS_INTERVAL_SECONDS:-172800}"
NOW_EPOCH="${IOS_REFRESH_NOW_EPOCH:-$(date +%s)}"
XCRUN_BIN="${XCRUN_BIN:-xcrun}"
PLUTIL_BIN="${PLUTIL_BIN:-/usr/bin/plutil}"

if [ -z "$DEVICE_ID" ]; then
  echo "error: IOS_DEVICE_ID is required. Find it with: xcrun devicectl list devices" >&2
  exit 2
fi

if [ -f "$SUCCESS_FILE" ]; then
  LAST_SUCCESS_EPOCH="$(sed -n '1p' "$SUCCESS_FILE")"
  case "$LAST_SUCCESS_EPOCH" in
    ''|*[!0-9]*)
      ;;
    *)
      SUCCESS_AGE_SECONDS=$((NOW_EPOCH - LAST_SUCCESS_EPOCH))
      if [ "$SUCCESS_AGE_SECONDS" -ge 0 ] && [ "$SUCCESS_AGE_SECONDS" -lt "$SUCCESS_INTERVAL_SECONDS" ]; then
        exit 0
      fi
      ;;
  esac
fi

DEVICE_JSON="$(mktemp "${TMPDIR:-/tmp}/pods-refresh-device.XXXXXX")"
cleanup() {
  rm -f "$DEVICE_JSON"
}
trap cleanup EXIT

if ! "$XCRUN_BIN" devicectl device info details \
  --device "$DEVICE_ID" \
  --timeout 15 \
  --json-output "$DEVICE_JSON" \
  --quiet; then
  echo "Pods refresh is due, but device availability could not be checked; will retry." >&2
  exit 75
fi

TUNNEL_STATE="$("$PLUTIL_BIN" -extract result.connectionProperties.tunnelState raw -o - "$DEVICE_JSON" 2>/dev/null || true)"
if [ "$TUNNEL_STATE" != "connected" ]; then
  echo "Pods refresh is due, but the iPhone is unavailable; will retry." >&2
  exit 75
fi

"$REFRESH_SCRIPT"
