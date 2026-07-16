#!/bin/sh
# Install a launchd job that checks every 15 minutes and refreshes after 48 hours.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_ID="${IOS_DEVICE_ID:-}"
XCODE_DESTINATION="${IOS_XCODE_DESTINATION:-}"
TEAM_ID="${IOS_TEAM_ID:-}"
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

mkdir -p "$(dirname "$PLIST_OUT")"
mkdir -p "$ROOT/ios/build"
sed \
  -e "s#__ROOT__#$ROOT#g" \
  -e "s#__DEVICE_ID__#$DEVICE_ID#g" \
  -e "s#__XCODE_DESTINATION__#$XCODE_DESTINATION#g" \
  -e "s#__TEAM_ID__#$TEAM_ID#g" \
  "$ROOT/ios/dev.mcgiv.pods.refresh.plist.template" > "$PLIST_OUT"

launchctl bootout "$DOMAIN" "$PLIST_OUT" >/dev/null 2>&1 || true
launchctl bootstrap "$DOMAIN" "$PLIST_OUT"
launchctl enable "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
echo "Installed launchd job at $PLIST_OUT"
echo "It checks at login and every 15 minutes, refreshes after 48 hours, and retries while the phone is unavailable."
echo "Install logs: ~/Library/Logs/Pods/ios-refresh.log"
