#!/bin/sh
# DEPRECATED as of 1 October 2026. Do not review, extend, or append to this script.
# See ios/DEPRECATED.md.
# Emit each Pods signing warning once per provisioning profile and severity.
set -eu
echo "warning: deprecated as of 1 October 2026; do not extend this iPhone app/signing/install tooling. See ios/DEPRECATED.md." >&2

LEVEL="${1:-}"
PROFILE_UUID="${2:-}"
PROFILE_EXPIRATION_EPOCH="${3:-}"
MESSAGE="${4:-}"
ALERT_STATE_FILE="${IOS_ALERT_STATE_FILE:-$HOME/Library/Application Support/PodsRefresh/alert-state}"
OSASCRIPT_BIN="${IOS_OSASCRIPT_BIN:-/usr/bin/osascript}"
ALERTS_ENABLED="${IOS_SIGNING_ALERTS_ENABLED:-1}"

case "$LEVEL" in
  warning|critical|expired|failure) ;;
  *)
    echo "error: unsupported signing alert level '$LEVEL'" >&2
    exit 2
    ;;
esac
case "$PROFILE_UUID" in
  *[!A-Za-z0-9._-]*|'')
    echo "error: invalid signing alert profile UUID" >&2
    exit 2
    ;;
esac
case "$PROFILE_EXPIRATION_EPOCH" in
  ''|*[!0-9]*)
    echo "error: invalid signing alert expiration" >&2
    exit 2
    ;;
esac
if [ -z "$MESSAGE" ]; then
  echo "error: signing alert message is required" >&2
  exit 2
fi

ALERT_KEY="${PROFILE_UUID}:${LEVEL}"
if [ -f "$ALERT_STATE_FILE" ] && grep -Fxq "$ALERT_KEY" "$ALERT_STATE_FILE"; then
  exit 0
fi
if [ "$ALERTS_ENABLED" != "1" ]; then
  exit 0
fi

case "$LEVEL" in
  warning) TITLE="Pods Signing Warning" ;;
  critical) TITLE="Pods Signing Critical" ;;
  expired) TITLE="Pods Signing Expired" ;;
  failure) TITLE="Pods Refresh Failed" ;;
esac

"$OSASCRIPT_BIN" - "$TITLE" "$MESSAGE" <<'APPLESCRIPT'
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT

mkdir -p "$(dirname "$ALERT_STATE_FILE")"
printf '%s\n' "$ALERT_KEY" >> "$ALERT_STATE_FILE"
