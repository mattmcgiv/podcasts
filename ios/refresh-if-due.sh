#!/bin/sh
# launchd entrypoint for unattended Pods refresh checks.
set -eu
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_ID="${IOS_DEVICE_ID:-}"
REFRESH_SCRIPT="${IOS_REFRESH_SCRIPT:-$ROOT/ios/refresh-device.sh}"
SUCCESS_FILE="${IOS_REFRESH_SUCCESS_FILE:-$HOME/Library/Application Support/PodsRefresh/last-success-epoch}"
PROFILE_STATE_FILE="${IOS_REFRESH_PROFILE_STATE_FILE:-$HOME/Library/Application Support/PodsRefresh/profile-state}"
SUCCESS_INTERVAL_SECONDS="${IOS_REFRESH_SUCCESS_INTERVAL_SECONDS:-172800}"
PROFILE_RENEWAL_WINDOW_SECONDS="${IOS_PROFILE_RENEWAL_WINDOW_SECONDS:-259200}"
PROFILE_WARNING_SECONDS="${IOS_PROFILE_WARNING_SECONDS:-172800}"
PROFILE_CRITICAL_SECONDS="${IOS_PROFILE_CRITICAL_SECONDS:-43200}"
NOW_EPOCH="${IOS_REFRESH_NOW_EPOCH:-$(date +%s)}"
XCRUN_BIN="${XCRUN_BIN:-xcrun}"
PLUTIL_BIN="${PLUTIL_BIN:-/usr/bin/plutil}"
SIGNING_ALERT_BIN="${IOS_SIGNING_ALERT_BIN:-$ROOT/ios/signing-alert.sh}"

if [ -z "$DEVICE_ID" ]; then
  echo "error: IOS_DEVICE_ID is required. Find it with: xcrun devicectl list devices" >&2
  exit 2
fi

FORCE_PROFILE_RENEWAL=1
PROFILE_UUID=""
PROFILE_EXPIRATION_EPOCH=""
PROFILE_REMAINING_SECONDS=""
if [ -f "$PROFILE_STATE_FILE" ]; then
  PROFILE_UUID="$(sed -n 's/^profile_uuid=//p' "$PROFILE_STATE_FILE" | sed -n '1p')"
  PROFILE_EXPIRATION_EPOCH="$(sed -n 's/^profile_expiration_epoch=//p' "$PROFILE_STATE_FILE" | sed -n '1p')"
  case "$PROFILE_EXPIRATION_EPOCH" in
    ''|*[!0-9]*)
      ;;
    *)
      PROFILE_REMAINING_SECONDS=$((PROFILE_EXPIRATION_EPOCH - NOW_EPOCH))
      if [ "$PROFILE_REMAINING_SECONDS" -gt "$PROFILE_RENEWAL_WINDOW_SECONDS" ]; then
        FORCE_PROFILE_RENEWAL=0
      fi
      ;;
  esac
fi

alert_profile_risk() {
  case "$PROFILE_UUID" in
    *[!A-Za-z0-9._-]*|'') return ;;
  esac
  case "$PROFILE_EXPIRATION_EPOCH:$PROFILE_REMAINING_SECONDS" in
    *[!0-9:-]*|:*|*:) return ;;
  esac
  if [ "$PROFILE_REMAINING_SECONDS" -le 0 ]; then
    ALERT_LEVEL="expired"
    ALERT_MESSAGE="Pods signing has expired. Connect the iPhone to this Mac so Pods can be renewed."
  elif [ "$PROFILE_REMAINING_SECONDS" -le "$PROFILE_CRITICAL_SECONDS" ]; then
    ALERT_LEVEL="critical"
    ALERT_MESSAGE="Pods signing expires within 12 hours. Keep the iPhone reachable from this Mac."
  elif [ "$PROFILE_REMAINING_SECONDS" -le "$PROFILE_WARNING_SECONDS" ]; then
    ALERT_LEVEL="warning"
    ALERT_MESSAGE="Pods signing expires within 48 hours. Keep the iPhone reachable from this Mac."
  else
    return
  fi
  "$SIGNING_ALERT_BIN" "$ALERT_LEVEL" "$PROFILE_UUID" "$PROFILE_EXPIRATION_EPOCH" "$ALERT_MESSAGE" ||
    echo "warning: could not deliver Pods signing alert" >&2
}

if [ "$FORCE_PROFILE_RENEWAL" != "1" ] && [ -f "$SUCCESS_FILE" ]; then
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
  alert_profile_risk
  exit 75
fi

TUNNEL_STATE="$("$PLUTIL_BIN" -extract result.connectionProperties.tunnelState raw -o - "$DEVICE_JSON" 2>/dev/null || true)"
if [ "$TUNNEL_STATE" != "connected" ]; then
  echo "Pods refresh is due, but the iPhone is unavailable; will retry." >&2
  alert_profile_risk
  exit 75
fi

IOS_FORCE_PROFILE_RENEWAL="$FORCE_PROFILE_RENEWAL" "$REFRESH_SCRIPT" || {
  REFRESH_STATUS=$?
  ALERT_PROFILE_UUID="${PROFILE_UUID:-unknown-profile}"
  ALERT_PROFILE_EXPIRATION_EPOCH="${PROFILE_EXPIRATION_EPOCH:-$NOW_EPOCH}"
  "$SIGNING_ALERT_BIN" failure "$ALERT_PROFILE_UUID" "$ALERT_PROFILE_EXPIRATION_EPOCH" \
    "Pods could not renew its iPhone signing. Xcode account attention may be required; the job will keep retrying." ||
    echo "warning: could not deliver Pods refresh failure alert" >&2
  exit "$REFRESH_STATUS"
}
