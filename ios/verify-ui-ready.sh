#!/bin/sh
# Wait for the installed app to publish fresh UI-ready evidence.
# This reads from the app data container and does not mutate the device.
set -eu

DEVICE_ID="${IOS_DEVICE_ID:-}"
BUNDLE_ID="${IOS_BUNDLE_ID:-}"
READY_AFTER_EPOCH="${IOS_UI_READY_AFTER_EPOCH:-}"
EXPECTED_BUILD_ID="${IOS_EXPECTED_BUILD_ID:-}"
EXPECTED_REFRESH_NONCE="${IOS_EXPECTED_REFRESH_NONCE:-}"
TIMEOUT_SECONDS="${IOS_UI_READY_TIMEOUT_SECONDS:-30}"
POLL_INTERVAL_SECONDS="${IOS_UI_READY_POLL_INTERVAL_SECONDS:-1}"
XCRUN_BIN="${XCRUN_BIN:-xcrun}"
READY_SOURCE="Library/Application Support/Pods/ui-ready.txt"

if [ -z "$DEVICE_ID" ] || [ -z "$BUNDLE_ID" ] || [ -z "$READY_AFTER_EPOCH" ] || [ -z "$EXPECTED_BUILD_ID" ] || [ -z "$EXPECTED_REFRESH_NONCE" ]; then
  echo "error: IOS_DEVICE_ID, IOS_BUNDLE_ID, IOS_UI_READY_AFTER_EPOCH, IOS_EXPECTED_BUILD_ID, and IOS_EXPECTED_REFRESH_NONCE are required"
  exit 2
fi
case "$READY_AFTER_EPOCH" in
  *[!0-9]*|'')
    echo "error: IOS_UI_READY_AFTER_EPOCH must be a nonnegative integer"
    exit 2
    ;;
esac
case "$TIMEOUT_SECONDS" in
  *[!0-9]*|'')
    echo "error: IOS_UI_READY_TIMEOUT_SECONDS must be a nonnegative integer"
    exit 2
    ;;
esac
case "$POLL_INTERVAL_SECONDS" in
  *[!0-9]*|'')
    echo "error: IOS_UI_READY_POLL_INTERVAL_SECONDS must be a nonnegative integer"
    exit 2
    ;;
esac

READY_FILE="$(mktemp "${TMPDIR:-/tmp}/pods-ui-ready.XXXXXX")"
cleanup() {
  rm -f "$READY_FILE"
}
trap cleanup EXIT

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
last_reason="marker unavailable"

while :; do
  rm -f "$READY_FILE"
  if "$XCRUN_BIN" devicectl device copy from \
    --device "$DEVICE_ID" \
    --source "$READY_SOURCE" \
    --destination "$READY_FILE" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --timeout 10 \
    --quiet; then
    ready_epoch=""
    ready_build_id=""
    ready_refresh_nonce=""
    ready_extra=""
    IFS=' ' read -r ready_epoch ready_build_id ready_refresh_nonce ready_extra < "$READY_FILE" || true
    case "$ready_epoch" in
      *[!0-9]*|'')
        last_reason="marker epoch is invalid"
        ;;
      *)
        if [ -n "$ready_extra" ]; then
          last_reason="marker format is invalid"
        elif [ "$ready_epoch" -lt "$READY_AFTER_EPOCH" ]; then
          last_reason="marker is stale"
        elif [ "$ready_build_id" != "$EXPECTED_BUILD_ID" ]; then
          last_reason="marker build ID '$ready_build_id' does not match '$EXPECTED_BUILD_ID'"
        elif [ "$ready_refresh_nonce" != "$EXPECTED_REFRESH_NONCE" ]; then
          last_reason="marker refresh nonce does not match this install attempt"
        else
          echo "Pods UI ready at epoch $ready_epoch for build $ready_build_id install $ready_refresh_nonce"
          exit 0
        fi
        ;;
    esac
  else
    last_reason="marker copy failed"
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    break
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done

echo "error: Pods UI readiness was not confirmed within ${TIMEOUT_SECONDS}s ($last_reason)"
exit 1
