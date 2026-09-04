#!/bin/sh
# DEPRECATED as of 1 October 2026. Do not review, extend, or append to this script.
# See ios/DEPRECATED.md.
set -eu
echo "warning: deprecated as of 1 October 2026; do not extend this iPhone app/signing/install tooling. See ios/DEPRECATED.md." >&2

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  file="$1"
  pattern="$2"
  if ! grep -Fq -- "$pattern" "$file"; then
    echo "Expected $file to contain: $pattern" >&2
    echo "--- $file ---" >&2
    sed -n '1,200p' "$file" >&2
    fail "missing expected content"
  fi
}

assert_file_exists() {
  [ -e "$1" ] || fail "expected file to exist: $1"
}

assert_file_equals() {
  file="$1"
  expected="$2"
  actual="$(cat "$file")"
  [ "$actual" = "$expected" ] || fail "expected $file to contain '$expected', got '$actual'"
}

write_xcrun_device_stub() {
  bin_dir="$1"
  cat > "$bin_dir/xcrun" <<'STUB'
#!/bin/sh
command="$*"
if [ -n "${XCRUN_LOG:-}" ]; then
  printf '%s\n' "$command" >> "$XCRUN_LOG"
fi
json_output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--json-output" ]; then
    shift
    json_output="$1"
    break
  fi
  shift
done
if [ -n "$json_output" ]; then
  case "$command" in
    *"device info details"*)
      cat > "$json_output" <<JSON
{
  "result": {
    "connectionProperties": { "tunnelState": "${DEVICE_DETAILS_TUNNEL_STATE:-${DEVICE_TUNNEL_STATE:-unavailable}}" }
  }
}
JSON
      ;;
    *"device info processes"*)
      cat > "$json_output" <<JSON
{
  "result": {
    "runningProcesses": [
      { "processIdentifier": ${XCRUN_PROCESS_PID:-42}, "executable": "${XCRUN_PROCESS_EXECUTABLE:-file:///private/var/containers/Bundle/Application/TEST/Pods.app/Pods}" }
    ]
  }
}
JSON
      ;;
    *"device process launch"*)
      cat > "$json_output" <<JSON
{
  "result": {
    "process": {
      "processIdentifier": ${XCRUN_LAUNCHED_PID:-42},
      "executable": "${XCRUN_LAUNCHED_EXECUTABLE:-file:///private/var/containers/Bundle/Application/TEST/Pods.app/Pods}"
    }
  }
}
JSON
      ;;
    *)
      cat > "$json_output" <<JSON
{
  "result": {
    "devices": [
      {
        "identifier": "device-id",
        "connectionProperties": { "tunnelState": "${DEVICE_LIST_TUNNEL_STATE:-${DEVICE_TUNNEL_STATE:-unavailable}}" }
      }
    ]
  }
}
JSON
      ;;
  esac
fi
case "$command" in
  *"device process launch"*) exit "${XCRUN_LAUNCH_EXIT:-0}" ;;
esac
exit 0
STUB
  chmod +x "$bin_dir/xcrun"
}

test_profile_metadata_reports_identity_and_expiration() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin"
  cat > "$tmp/profile.mobileprovision" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>UUID</key>
  <string>fresh-profile</string>
  <key>CreationDate</key>
  <date>2026-07-23T12:00:00Z</date>
  <key>ExpirationDate</key>
  <date>2026-07-30T12:00:00Z</date>
  <key>Entitlements</key>
  <dict>
    <key>application-identifier</key>
    <string>TEAMID.dev.mcgiv.pods</string>
  </dict>
</dict>
</plist>
PLIST
  cat > "$tmp/bin/security" <<'STUB'
#!/bin/sh
for argument in "$@"; do
  profile="$argument"
done
cat "$profile"
STUB
  chmod +x "$tmp/bin/security"

  IOS_SECURITY_BIN="$tmp/bin/security" \
    "$ROOT/ios/profile-metadata.sh" "$tmp/profile.mobileprovision" > "$tmp/metadata"

  assert_file_contains "$tmp/metadata" "profile_uuid=fresh-profile"
  assert_file_contains "$tmp/metadata" "profile_creation_epoch=1784808000"
  assert_file_contains "$tmp/metadata" "profile_expiration_epoch=1785412800"
  assert_file_contains "$tmp/metadata" "application_identifier=TEAMID.dev.mcgiv.pods"
}

test_signing_alerts_escalate_without_spamming() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/osascript" <<'STUB'
#!/bin/sh
cat >/dev/null
printf '%s\n' "$*" >> "$OSASCRIPT_LOG"
STUB
  chmod +x "$tmp/bin/osascript"

  IOS_ALERT_STATE_FILE="$tmp/alert-state" \
  IOS_OSASCRIPT_BIN="$tmp/bin/osascript" \
  OSASCRIPT_LOG="$tmp/osascript.log" \
    "$ROOT/ios/signing-alert.sh" warning profile-one 900000 "Pods signing expires in 48 hours"
  IOS_ALERT_STATE_FILE="$tmp/alert-state" \
  IOS_OSASCRIPT_BIN="$tmp/bin/osascript" \
  OSASCRIPT_LOG="$tmp/osascript.log" \
    "$ROOT/ios/signing-alert.sh" warning profile-one 900000 "Pods signing expires in 48 hours"
  IOS_ALERT_STATE_FILE="$tmp/alert-state" \
  IOS_OSASCRIPT_BIN="$tmp/bin/osascript" \
  OSASCRIPT_LOG="$tmp/osascript.log" \
    "$ROOT/ios/signing-alert.sh" critical profile-one 900000 "Pods signing expires in 12 hours"

  alert_count="$(wc -l < "$tmp/osascript.log" | tr -d '[:space:]')"
  [ "$alert_count" = "2" ] || fail "expected one warning and one critical alert, got $alert_count"
  assert_file_contains "$tmp/alert-state" "profile-one:warning"
  assert_file_contains "$tmp/alert-state" "profile-one:critical"
}

test_signing_reminders_follow_verified_profile_expiration() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/osascript" <<'STUB'
#!/bin/sh
cat >/dev/null
printf '%s\n' "$*" > "$OSASCRIPT_LOG"
STUB
  chmod +x "$tmp/bin/osascript"

  IOS_OSASCRIPT_BIN="$tmp/bin/osascript" \
  IOS_PROFILE_WARNING_SECONDS=172800 \
  IOS_PROFILE_CRITICAL_SECONDS=43200 \
  OSASCRIPT_LOG="$tmp/osascript.log" \
    "$ROOT/ios/update-signing-reminders.sh" profile-one 900000

  assert_file_equals "$tmp/osascript.log" "- 727200 856800 900000 profile-one"
}

test_install_agent_generates_retrying_48_hour_refresh_plist() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home" "$tmp/bin"
  cp "$ROOT/ios/install-refresh-agent.sh" "$tmp/repo/ios/install-refresh-agent.sh"
  cp "$ROOT/ios/dev.mcgiv.pods.refresh.plist.template" "$tmp/repo/ios/dev.mcgiv.pods.refresh.plist.template"
  chmod +x "$tmp/repo/ios/install-refresh-agent.sh"

  cat > "$tmp/bin/launchctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
exit 0
STUB
  chmod +x "$tmp/bin/launchctl"

  LAUNCHCTL_LOG="$tmp/launchctl.log" \
  HOME="$tmp/home" \
  PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  IOS_DEVICE_ID="device-id" \
  IOS_XCODE_DESTINATION="platform=iOS,id=xcode-id" \
  IOS_TEAM_ID="TEAMID" \
    "$tmp/repo/ios/install-refresh-agent.sh" >/dev/null

  plist="$tmp/home/Library/LaunchAgents/dev.mcgiv.pods.refresh.plist"
  assert_file_exists "$plist"
  assert_file_contains "$plist" "refresh-if-due.sh"
  assert_file_contains "$plist" "<integer>900</integer>"
  assert_file_contains "$plist" "<key>IOS_REFRESH_SUCCESS_INTERVAL_SECONDS</key>"
  assert_file_contains "$plist" "<string>172800</string>"
  assert_file_contains "$plist" "<key>IOS_PROFILE_RENEWAL_WINDOW_SECONDS</key>"
  assert_file_contains "$plist" "<string>259200</string>"
  assert_file_contains "$plist" "<key>IOS_PROFILE_WARNING_SECONDS</key>"
  assert_file_contains "$plist" "<string>172800</string>"
  assert_file_contains "$plist" "<key>IOS_PROFILE_CRITICAL_SECONDS</key>"
  assert_file_contains "$plist" "<string>43200</string>"
  assert_file_contains "$plist" "<key>IOS_NOTIFY_FAILURE</key>"
  assert_file_contains "$plist" "<string>0</string>"
  assert_file_contains "$plist" "<key>IOS_SIGNING_ALERTS_ENABLED</key>"
  assert_file_contains "$plist" "<string>1</string>"
  assert_file_contains "$plist" "<key>RunAtLoad</key>"
  assert_file_contains "$plist" "<true/>"
  assert_file_contains "$plist" "<key>PATH</key>"
  assert_file_contains "$plist" "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  assert_file_contains "$tmp/launchctl.log" "bootstrap gui/"

  LAUNCHCTL_LOG="$tmp/launchctl.log" \
  HOME="$tmp/home" \
  PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  IOS_DEVICE_ID="device-id" \
  IOS_XCODE_DESTINATION="platform=iOS,id=xcode-id" \
  IOS_TEAM_ID="TEAMID" \
  IOS_REFRESH_CHECK_INTERVAL_SECONDS=60 \
  IOS_REFRESH_SUCCESS_INTERVAL_SECONDS=120 \
    "$tmp/repo/ios/install-refresh-agent.sh" >/dev/null

  assert_file_contains "$plist" "<integer>60</integer>"
  assert_file_contains "$plist" "<string>120</string>"
}

test_successful_refresh_records_success_time() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home" "$tmp/bin" "$tmp/build/DerivedData/Build/Products/Debug-iphoneos/Pods.app"
  cp "$ROOT/ios/refresh-device.sh" "$tmp/repo/ios/refresh-device.sh"
  chmod +x "$tmp/repo/ios/refresh-device.sh"

  cat > "$tmp/repo/ios/check-xcode.sh" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$tmp/repo/ios/check-xcode.sh"

  cat > "$tmp/bin/xcodebuild" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$XCODEBUILD_LOG"
exit 0
STUB
  chmod +x "$tmp/bin/xcodebuild"

  cat > "$tmp/profile-metadata.sh" <<'STUB'
#!/bin/sh
cat <<'STATE'
profile_uuid=fresh-profile
profile_creation_epoch=10000
profile_expiration_epoch=900000
application_identifier=TEAMID.dev.mcgiv.pods
STATE
STUB
  chmod +x "$tmp/profile-metadata.sh"

  cat > "$tmp/update-reminders.sh" <<'STUB'
#!/bin/sh
printf '%s %s\n' "$1" "$2" > "$REMINDER_LOG"
STUB
  chmod +x "$tmp/update-reminders.sh"

  cat > "$tmp/build/DerivedData/Build/Products/Debug-iphoneos/Pods.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>dev.mcgiv.pods</string>
  <key>CFBundleExecutable</key>
  <string>Pods</string>
  <key>PodsBuildID</key>
  <string>test-build</string>
  <key>PodsRefreshNonce</key>
  <string>test-nonce</string>
</dict>
</plist>
PLIST
  touch "$tmp/build/DerivedData/Build/Products/Debug-iphoneos/Pods.app/embedded.mobileprovision"

  write_xcrun_device_stub "$tmp/bin"

  HOME="$tmp/home" \
  IOS_BUILD_DIR="$tmp/build" \
  IOS_DEVICE_ID="device-id" \
  IOS_XCODE_DESTINATION="platform=iOS,id=xcode-id" \
  IOS_TEAM_ID="TEAMID" \
  IOS_SKIP_WEB_ASSETS=1 \
  IOS_SOURCE_BUILD_ID="test-build" \
  IOS_REFRESH_NONCE="test-nonce" \
  IOS_UI_READY_CHECK=: \
  IOS_UI_STABILITY_SECONDS=0 \
  IOS_REFRESH_NOW_EPOCH=12345 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  IOS_REFRESH_PROFILE_STATE_FILE="$tmp/profile-state" \
  IOS_PROFILE_METADATA_BIN="$tmp/profile-metadata.sh" \
  IOS_SIGNING_REMINDER_BIN="$tmp/update-reminders.sh" \
  REMINDER_LOG="$tmp/reminder.log" \
  DEVICE_LIST_TUNNEL_STATE=disconnected \
  DEVICE_DETAILS_TUNNEL_STATE=connected \
  XCODEBUILD_BIN="$tmp/bin/xcodebuild" \
  XCODEBUILD_LOG="$tmp/xcodebuild.log" \
  XCRUN_BIN="$tmp/bin/xcrun" \
  XCRUN_LOG="$tmp/xcrun.log" \
    "$tmp/repo/ios/refresh-device.sh"

  assert_file_equals "$tmp/last-success" "12345"
  assert_file_contains "$tmp/profile-state" "profile_uuid=fresh-profile"
  assert_file_contains "$tmp/profile-state" "profile_creation_epoch=10000"
  assert_file_contains "$tmp/profile-state" "profile_expiration_epoch=900000"
  assert_file_contains "$tmp/profile-state" "last_success_epoch=12345"
  assert_file_equals "$tmp/reminder.log" "fresh-profile 900000"
  assert_file_contains "$tmp/xcodebuild.log" "-skipPackagePluginValidation"
  assert_file_contains "$tmp/xcodebuild.log" "-onlyUsePackageVersionsFromResolvedFile"
  assert_file_contains "$tmp/xcodebuild.log" "PODS_BUILD_ID=test-build"
  assert_file_contains "$tmp/xcodebuild.log" "PODS_REFRESH_NONCE=test-nonce"
  assert_file_contains "$tmp/xcrun.log" "devicectl device install app --device device-id"
  assert_file_contains "$tmp/xcrun.log" "devicectl device process launch --device device-id --terminate-existing --json-output"
  assert_file_contains "$tmp/xcrun.log" "devicectl device info processes --device device-id"

  rm -f "$tmp/last-success"
  set +e
  HOME="$tmp/home" \
  IOS_BUILD_DIR="$tmp/build" \
  IOS_DEVICE_ID="device-id" \
  IOS_XCODE_DESTINATION="platform=iOS,id=xcode-id" \
  IOS_TEAM_ID="TEAMID" \
  IOS_SKIP_WEB_ASSETS=1 \
  IOS_NOTIFY_FAILURE=0 \
  IOS_SOURCE_BUILD_ID="test-build" \
  IOS_REFRESH_NONCE="test-nonce" \
  IOS_UI_READY_CHECK=: \
  IOS_UI_STABILITY_SECONDS=0 \
  IOS_REFRESH_NOW_EPOCH=12345 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  IOS_REFRESH_PROFILE_STATE_FILE="$tmp/profile-state" \
  IOS_PROFILE_METADATA_BIN="$tmp/profile-metadata.sh" \
  IOS_SIGNING_REMINDER_BIN="$tmp/update-reminders.sh" \
  REMINDER_LOG="$tmp/reminder.log" \
  DEVICE_DETAILS_TUNNEL_STATE=connected \
  XCODEBUILD_BIN="$tmp/bin/xcodebuild" \
  XCODEBUILD_LOG="$tmp/xcodebuild.log" \
  XCRUN_BIN="$tmp/bin/xcrun" \
  XCRUN_LOG="$tmp/xcrun.log" \
  XCRUN_PROCESS_PID=43 \
    "$tmp/repo/ios/refresh-device.sh"
  mismatched_process_status=$?
  set -e

  [ "$mismatched_process_status" -ne 0 ] || fail "a different surviving PID must fail refresh verification"
  [ ! -e "$tmp/last-success" ] || fail "a PID mismatch must not advance the success marker"
}

test_forced_renewal_rejects_expiring_profile_before_install() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home" "$tmp/bin" "$tmp/build/DerivedData/Build/Products/Debug-iphoneos/Pods.app"
  cp "$ROOT/ios/refresh-device.sh" "$tmp/repo/ios/refresh-device.sh"
  chmod +x "$tmp/repo/ios/refresh-device.sh"

  cat > "$tmp/repo/ios/check-xcode.sh" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$tmp/repo/ios/check-xcode.sh"

  cat > "$tmp/bin/xcodebuild" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$tmp/bin/xcodebuild"

  cat > "$tmp/profile-metadata.sh" <<'STUB'
#!/bin/sh
cat <<'STATE'
profile_uuid=reused-expiring-profile
profile_creation_epoch=100000
profile_expiration_epoch=200100
application_identifier=TEAMID.dev.mcgiv.pods
STATE
STUB
  chmod +x "$tmp/profile-metadata.sh"

  cat > "$tmp/build/DerivedData/Build/Products/Debug-iphoneos/Pods.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>dev.mcgiv.pods</string>
  <key>CFBundleExecutable</key>
  <string>Pods</string>
  <key>PodsBuildID</key>
  <string>test-build</string>
  <key>PodsRefreshNonce</key>
  <string>test-nonce</string>
</dict>
</plist>
PLIST
  touch "$tmp/build/DerivedData/Build/Products/Debug-iphoneos/Pods.app/embedded.mobileprovision"
  write_xcrun_device_stub "$tmp/bin"

  set +e
  HOME="$tmp/home" \
  IOS_BUILD_DIR="$tmp/build" \
  IOS_DEVICE_ID="device-id" \
  IOS_XCODE_DESTINATION="platform=iOS,id=xcode-id" \
  IOS_TEAM_ID="TEAMID" \
  IOS_SKIP_WEB_ASSETS=1 \
  IOS_NOTIFY_FAILURE=0 \
  IOS_FORCE_PROFILE_RENEWAL=1 \
  IOS_PROFILE_FRESH_VALIDITY_SECONDS=518400 \
  IOS_PROFILE_METADATA_BIN="$tmp/profile-metadata.sh" \
  IOS_SOURCE_BUILD_ID="test-build" \
  IOS_REFRESH_NONCE="test-nonce" \
  IOS_REFRESH_NOW_EPOCH=200000 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  IOS_REFRESH_PROFILE_STATE_FILE="$tmp/profile-state" \
  DEVICE_DETAILS_TUNNEL_STATE=connected \
  XCODEBUILD_BIN="$tmp/bin/xcodebuild" \
  XCRUN_BIN="$tmp/bin/xcrun" \
  XCRUN_LOG="$tmp/xcrun.log" \
    "$tmp/repo/ios/refresh-device.sh"
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "forced renewal must reject a profile with only seconds remaining"
  [ ! -e "$tmp/last-success" ] || fail "rejected profile must not advance the success marker"
  [ ! -e "$tmp/profile-state" ] || fail "rejected profile must not update profile state"
  if grep -Fq "devicectl device install app" "$tmp/xcrun.log"; then
    fail "an expiring profile must be rejected before installation"
  fi
}

test_forced_renewal_archives_only_expiring_matching_profile() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home" "$tmp/bin" "$tmp/cache" "$tmp/build/DerivedData/Build/Products/Debug-iphoneos/Pods.app"
  cp "$ROOT/ios/refresh-device.sh" "$tmp/repo/ios/refresh-device.sh"
  chmod +x "$tmp/repo/ios/refresh-device.sh"
  touch "$tmp/cache/pods-expiring.mobileprovision"
  touch "$tmp/cache/unrelated.mobileprovision"

  cat > "$tmp/repo/ios/check-xcode.sh" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$tmp/repo/ios/check-xcode.sh"

  cat > "$tmp/bin/xcodebuild" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$tmp/bin/xcodebuild"

  cat > "$tmp/profile-metadata.sh" <<'STUB'
#!/bin/sh
case "$(basename "$1")" in
  pods-expiring.mobileprovision)
    uuid="pods-expiring"
    expiration=200100
    application_identifier="TEAMID.dev.mcgiv.pods"
    ;;
  unrelated.mobileprovision)
    uuid="unrelated"
    expiration=200100
    application_identifier="OTHERID.other.app"
    ;;
  embedded.mobileprovision)
    uuid="pods-fresh"
    expiration=900000
    application_identifier="TEAMID.dev.mcgiv.pods"
    ;;
  *)
    exit 2
    ;;
esac
printf 'profile_uuid=%s\n' "$uuid"
printf 'profile_creation_epoch=100000\n'
printf 'profile_expiration_epoch=%s\n' "$expiration"
printf 'application_identifier=%s\n' "$application_identifier"
STUB
  chmod +x "$tmp/profile-metadata.sh"

  cat > "$tmp/build/DerivedData/Build/Products/Debug-iphoneos/Pods.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>dev.mcgiv.pods</string>
  <key>CFBundleExecutable</key>
  <string>Pods</string>
  <key>PodsBuildID</key>
  <string>test-build</string>
  <key>PodsRefreshNonce</key>
  <string>test-nonce</string>
</dict>
</plist>
PLIST
  touch "$tmp/build/DerivedData/Build/Products/Debug-iphoneos/Pods.app/embedded.mobileprovision"
  write_xcrun_device_stub "$tmp/bin"

  HOME="$tmp/home" \
  IOS_BUILD_DIR="$tmp/build" \
  IOS_DEVICE_ID="device-id" \
  IOS_XCODE_DESTINATION="platform=iOS,id=xcode-id" \
  IOS_TEAM_ID="TEAMID" \
  IOS_SKIP_WEB_ASSETS=1 \
  IOS_NOTIFY_FAILURE=0 \
  IOS_FORCE_PROFILE_RENEWAL=1 \
  IOS_PROFILE_FRESH_VALIDITY_SECONDS=518400 \
  IOS_PROFILE_METADATA_BIN="$tmp/profile-metadata.sh" \
  IOS_PROFILE_CACHE_DIRS="$tmp/cache" \
  IOS_PROFILE_BACKUP_DIR="$tmp/backups" \
  IOS_SOURCE_BUILD_ID="test-build" \
  IOS_REFRESH_NONCE="test-nonce" \
  IOS_REFRESH_NOW_EPOCH=200000 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  IOS_REFRESH_PROFILE_STATE_FILE="$tmp/profile-state" \
  IOS_UI_READY_CHECK=: \
  IOS_UI_STABILITY_SECONDS=0 \
  DEVICE_DETAILS_TUNNEL_STATE=connected \
  XCODEBUILD_BIN="$tmp/bin/xcodebuild" \
  XCRUN_BIN="$tmp/bin/xcrun" \
  XCRUN_LOG="$tmp/xcrun.log" \
    "$tmp/repo/ios/refresh-device.sh"

  [ ! -e "$tmp/cache/pods-expiring.mobileprovision" ] || fail "expiring Pods profile should leave Xcode's active cache"
  assert_file_exists "$tmp/backups/pods-expiring.mobileprovision"
  assert_file_exists "$tmp/cache/unrelated.mobileprovision"
}

test_unlaunchable_install_does_not_record_success() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home" "$tmp/bin" "$tmp/build/DerivedData/Build/Products/Debug-iphoneos/Pods.app"
  cp "$ROOT/ios/refresh-device.sh" "$tmp/repo/ios/refresh-device.sh"
  chmod +x "$tmp/repo/ios/refresh-device.sh"

  cat > "$tmp/repo/ios/check-xcode.sh" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$tmp/repo/ios/check-xcode.sh"

  cat > "$tmp/bin/xcodebuild" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$tmp/bin/xcodebuild"

  cat > "$tmp/profile-metadata.sh" <<'STUB'
#!/bin/sh
cat <<'STATE'
profile_uuid=fresh-profile
profile_creation_epoch=10000
profile_expiration_epoch=900000
application_identifier=TEAMID.dev.mcgiv.pods
STATE
STUB
  chmod +x "$tmp/profile-metadata.sh"

  cat > "$tmp/build/DerivedData/Build/Products/Debug-iphoneos/Pods.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>dev.mcgiv.pods</string>
  <key>CFBundleExecutable</key>
  <string>Pods</string>
  <key>PodsBuildID</key>
  <string>test-build</string>
  <key>PodsRefreshNonce</key>
  <string>test-nonce</string>
</dict>
</plist>
PLIST
  touch "$tmp/build/DerivedData/Build/Products/Debug-iphoneos/Pods.app/embedded.mobileprovision"
  write_xcrun_device_stub "$tmp/bin"

  set +e
  HOME="$tmp/home" \
  IOS_BUILD_DIR="$tmp/build" \
  IOS_DEVICE_ID="device-id" \
  IOS_XCODE_DESTINATION="platform=iOS,id=xcode-id" \
  IOS_TEAM_ID="TEAMID" \
  IOS_SKIP_WEB_ASSETS=1 \
  IOS_NOTIFY_FAILURE=0 \
  IOS_SOURCE_BUILD_ID="test-build" \
  IOS_REFRESH_NONCE="test-nonce" \
  IOS_REFRESH_NOW_EPOCH=12345 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  IOS_REFRESH_PROFILE_STATE_FILE="$tmp/profile-state" \
  IOS_PROFILE_METADATA_BIN="$tmp/profile-metadata.sh" \
  DEVICE_DETAILS_TUNNEL_STATE=connected \
  XCODEBUILD_BIN="$tmp/bin/xcodebuild" \
  XCRUN_BIN="$tmp/bin/xcrun" \
  XCRUN_LAUNCH_EXIT=1 \
  XCRUN_LOG="$tmp/xcrun.log" \
    "$tmp/repo/ios/refresh-device.sh"
  refresh_status=$?
  set -e

  [ "$refresh_status" -ne 0 ] || fail "a refresh whose installed app cannot launch must fail"
  if [ -e "$tmp/last-success" ]; then
    fail "an unlaunchable install must not advance the success marker"
  fi
  assert_file_contains "$tmp/xcrun.log" "devicectl device process launch"
}

test_failed_default_ui_ready_check_does_not_record_success() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home" "$tmp/bin" "$tmp/build/DerivedData/Build/Products/Debug-iphoneos/Pods.app"
  cp "$ROOT/ios/refresh-device.sh" "$tmp/repo/ios/refresh-device.sh"
  chmod +x "$tmp/repo/ios/refresh-device.sh"

  cat > "$tmp/repo/ios/check-xcode.sh" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$tmp/repo/ios/check-xcode.sh"

  cat > "$tmp/repo/ios/verify-ui-ready.sh" <<'STUB'
#!/bin/sh
set -eu
grep -Fq "devicectl device process launch" "$XCRUN_LOG" || exit 31
[ ! -e "$IOS_REFRESH_SUCCESS_FILE" ] || exit 32
printf '%s %s %s %s\n' "$IOS_UI_READY_AFTER_EPOCH" "$IOS_EXPECTED_BUILD_ID" "$IOS_EXPECTED_REFRESH_NONCE" "$IOS_BUNDLE_ID" > "$UI_READY_CHECK_LOG"
exit 23
STUB
  chmod +x "$tmp/repo/ios/verify-ui-ready.sh"

  cat > "$tmp/bin/xcodebuild" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$tmp/bin/xcodebuild"
  write_xcrun_device_stub "$tmp/bin"

  cat > "$tmp/profile-metadata.sh" <<'STUB'
#!/bin/sh
cat <<'STATE'
profile_uuid=fresh-profile
profile_creation_epoch=10000
profile_expiration_epoch=900000
application_identifier=TEAMID.dev.mcgiv.pods
STATE
STUB
  chmod +x "$tmp/profile-metadata.sh"

  cat > "$tmp/build/DerivedData/Build/Products/Debug-iphoneos/Pods.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>dev.mcgiv.pods</string>
  <key>CFBundleExecutable</key>
  <string>Pods</string>
  <key>PodsBuildID</key>
  <string>test-build</string>
  <key>PodsRefreshNonce</key>
  <string>test-nonce</string>
</dict>
</plist>
PLIST
  touch "$tmp/build/DerivedData/Build/Products/Debug-iphoneos/Pods.app/embedded.mobileprovision"

  set +e
  HOME="$tmp/home" \
  IOS_BUILD_DIR="$tmp/build" \
  IOS_DEVICE_ID="device-id" \
  IOS_XCODE_DESTINATION="platform=iOS,id=xcode-id" \
  IOS_TEAM_ID="TEAMID" \
  IOS_SKIP_WEB_ASSETS=1 \
  IOS_NOTIFY_FAILURE=0 \
  IOS_SOURCE_BUILD_ID="test-build" \
  IOS_REFRESH_NONCE="test-nonce" \
  IOS_REFRESH_NOW_EPOCH=23456 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  IOS_REFRESH_PROFILE_STATE_FILE="$tmp/profile-state" \
  IOS_PROFILE_METADATA_BIN="$tmp/profile-metadata.sh" \
  DEVICE_DETAILS_TUNNEL_STATE=connected \
  XCODEBUILD_BIN="$tmp/bin/xcodebuild" \
  XCRUN_BIN="$tmp/bin/xcrun" \
  XCRUN_LOG="$tmp/xcrun.log" \
  UI_READY_CHECK_LOG="$tmp/ui-ready-check.log" \
    "$tmp/repo/ios/refresh-device.sh"
  refresh_status=$?
  set -e

  [ "$refresh_status" -eq 23 ] || fail "a rejected UI readiness check should return its failure status, got $refresh_status"
  if [ -e "$tmp/last-success" ]; then
    fail "a refresh whose UI is not ready must not advance the success marker"
  fi
  assert_file_equals "$tmp/ui-ready-check.log" "23456 test-build test-nonce dev.mcgiv.pods"
}

test_ui_ready_verifier_requires_fresh_matching_build_marker() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin"

  cat > "$tmp/bin/xcrun" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$XCRUN_LOG"
destination=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--destination" ]; then
    shift
    destination="$1"
    break
  fi
  shift
done
[ -n "$destination" ] || exit 90
printf '%s\n' "$READY_MARKER" > "$destination"
STUB
  chmod +x "$tmp/bin/xcrun"

  set +e
  READY_MARKER="199 test-build test-nonce" \
  XCRUN_LOG="$tmp/xcrun.log" \
  XCRUN_BIN="$tmp/bin/xcrun" \
  IOS_DEVICE_ID="device-id" \
  IOS_BUNDLE_ID="dev.mcgiv.pods" \
  IOS_UI_READY_AFTER_EPOCH=200 \
  IOS_EXPECTED_BUILD_ID="test-build" \
  IOS_EXPECTED_REFRESH_NONCE="test-nonce" \
  IOS_UI_READY_TIMEOUT_SECONDS=0 \
    "$ROOT/ios/verify-ui-ready.sh"
  stale_status=$?

  READY_MARKER="200 other-build test-nonce" \
  XCRUN_LOG="$tmp/xcrun.log" \
  XCRUN_BIN="$tmp/bin/xcrun" \
  IOS_DEVICE_ID="device-id" \
  IOS_BUNDLE_ID="dev.mcgiv.pods" \
  IOS_UI_READY_AFTER_EPOCH=200 \
  IOS_EXPECTED_BUILD_ID="test-build" \
  IOS_EXPECTED_REFRESH_NONCE="test-nonce" \
  IOS_UI_READY_TIMEOUT_SECONDS=0 \
    "$ROOT/ios/verify-ui-ready.sh"
  wrong_build_status=$?

  READY_MARKER="200 test-build other-nonce" \
  XCRUN_LOG="$tmp/xcrun.log" \
  XCRUN_BIN="$tmp/bin/xcrun" \
  IOS_DEVICE_ID="device-id" \
  IOS_BUNDLE_ID="dev.mcgiv.pods" \
  IOS_UI_READY_AFTER_EPOCH=200 \
  IOS_EXPECTED_BUILD_ID="test-build" \
  IOS_EXPECTED_REFRESH_NONCE="test-nonce" \
  IOS_UI_READY_TIMEOUT_SECONDS=0 \
    "$ROOT/ios/verify-ui-ready.sh"
  wrong_nonce_status=$?

  READY_MARKER="200 test-build test-nonce" \
  XCRUN_LOG="$tmp/xcrun.log" \
  XCRUN_BIN="$tmp/bin/xcrun" \
  IOS_DEVICE_ID="device-id" \
  IOS_BUNDLE_ID="dev.mcgiv.pods" \
  IOS_UI_READY_AFTER_EPOCH=200 \
  IOS_EXPECTED_BUILD_ID="test-build" \
  IOS_EXPECTED_REFRESH_NONCE="test-nonce" \
  IOS_UI_READY_TIMEOUT_SECONDS=0 \
    "$ROOT/ios/verify-ui-ready.sh"
  matching_status=$?
  set -e

  [ "$stale_status" -ne 0 ] || fail "a stale UI-ready marker must be rejected"
  [ "$wrong_build_status" -ne 0 ] || fail "a UI-ready marker from another build must be rejected"
  [ "$wrong_nonce_status" -ne 0 ] || fail "a UI-ready marker from another install attempt must be rejected"
  [ "$matching_status" -eq 0 ] || fail "a fresh UI-ready marker for the installed build must be accepted"
  assert_file_contains "$tmp/xcrun.log" "devicectl device copy from"
  assert_file_contains "$tmp/xcrun.log" "--domain-type appDataContainer"
  assert_file_contains "$tmp/xcrun.log" "--domain-identifier dev.mcgiv.pods"
  assert_file_contains "$tmp/xcrun.log" "--source Library/Application Support/Pods/ui-ready.txt"
}

test_manual_refresh_checks_device_before_signing() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home" "$tmp/bin"
  cp "$ROOT/ios/refresh-device.sh" "$tmp/repo/ios/refresh-device.sh"
  chmod +x "$tmp/repo/ios/refresh-device.sh"

  cat > "$tmp/repo/ios/check-xcode.sh" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$tmp/repo/ios/check-xcode.sh"

  cat > "$tmp/bin/xcodebuild" <<'STUB'
#!/bin/sh
printf 'called\n' > "$XCODEBUILD_CALLED_FILE"
exit 0
STUB
  chmod +x "$tmp/bin/xcodebuild"

  write_xcrun_device_stub "$tmp/bin"

  set +e
  HOME="$tmp/home" \
  IOS_BUILD_DIR="$tmp/build" \
  IOS_DEVICE_ID="device-id" \
  IOS_XCODE_DESTINATION="platform=iOS,id=xcode-id" \
  IOS_TEAM_ID="TEAMID" \
  IOS_SKIP_WEB_ASSETS=1 \
  IOS_NOTIFY_FAILURE=0 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  DEVICE_TUNNEL_STATE=unavailable \
  XCODEBUILD_BIN="$tmp/bin/xcodebuild" \
  XCODEBUILD_CALLED_FILE="$tmp/xcodebuild-called" \
  XCRUN_BIN="$tmp/bin/xcrun" \
    "$tmp/repo/ios/refresh-device.sh"
  status=$?
  set -e

  [ "$status" -eq 75 ] || fail "an unavailable manual target should return temporary failure 75, got $status"
  if [ -e "$tmp/xcodebuild-called" ]; then
    fail "manual refresh must not sign while the phone is unavailable"
  fi
}

test_due_refresh_invokes_installer() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home" "$tmp/bin"
  cp "$ROOT/ios/refresh-if-due.sh" "$tmp/repo/ios/refresh-if-due.sh"
  chmod +x "$tmp/repo/ios/refresh-if-due.sh"

  cat > "$tmp/refresh-device.sh" <<'STUB'
#!/bin/sh
printf 'called\n' > "$REFRESH_CALLED_FILE"
STUB
  chmod +x "$tmp/refresh-device.sh"

  write_xcrun_device_stub "$tmp/bin"

  HOME="$tmp/home" \
  IOS_DEVICE_ID="device-id" \
  IOS_REFRESH_NOW_EPOCH=200000 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  IOS_REFRESH_SCRIPT="$tmp/refresh-device.sh" \
  REFRESH_CALLED_FILE="$tmp/refresh-called" \
  DEVICE_TUNNEL_STATE=connected \
  XCRUN_BIN="$tmp/bin/xcrun" \
    "$tmp/repo/ios/refresh-if-due.sh"

  assert_file_contains "$tmp/refresh-called" "called"
}

test_due_refresh_opens_available_device_tunnel() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home" "$tmp/bin"
  cp "$ROOT/ios/refresh-if-due.sh" "$tmp/repo/ios/refresh-if-due.sh"
  chmod +x "$tmp/repo/ios/refresh-if-due.sh"

  cat > "$tmp/refresh-device.sh" <<'STUB'
#!/bin/sh
printf 'called\n' > "$REFRESH_CALLED_FILE"
STUB
  chmod +x "$tmp/refresh-device.sh"

  cat > "$tmp/bin/xcrun" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$XCRUN_LOG"
json_output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--json-output" ]; then
    shift
    json_output="$1"
    break
  fi
  shift
done
case "$(cat "$XCRUN_LOG")" in
  *"device info details"*)
    cat > "$json_output" <<'JSON'
{ "result": { "connectionProperties": { "tunnelState": "connected" } } }
JSON
    ;;
  *)
    cat > "$json_output" <<'JSON'
{ "result": { "devices": [{ "connectionProperties": { "tunnelState": "disconnected" } }] } }
JSON
    ;;
esac
STUB
  chmod +x "$tmp/bin/xcrun"

  HOME="$tmp/home" \
  IOS_DEVICE_ID="device-id" \
  IOS_REFRESH_NOW_EPOCH=300000 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  IOS_REFRESH_SCRIPT="$tmp/refresh-device.sh" \
  REFRESH_CALLED_FILE="$tmp/refresh-called" \
  XCRUN_BIN="$tmp/bin/xcrun" \
  XCRUN_LOG="$tmp/xcrun.log" \
    "$tmp/repo/ios/refresh-if-due.sh"

  assert_file_contains "$tmp/refresh-called" "called"
  assert_file_contains "$tmp/xcrun.log" "devicectl device info details"
}

test_recent_success_skips_refresh() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home"
  cp "$ROOT/ios/refresh-if-due.sh" "$tmp/repo/ios/refresh-if-due.sh"
  chmod +x "$tmp/repo/ios/refresh-if-due.sh"
  printf '100000\n' > "$tmp/last-success"
  cat > "$tmp/profile-state" <<'STATE'
profile_uuid=fresh-profile
profile_expiration_epoch=500000
last_success_epoch=100000
STATE

  cat > "$tmp/refresh-device.sh" <<'STUB'
#!/bin/sh
printf 'called\n' > "$REFRESH_CALLED_FILE"
STUB
  chmod +x "$tmp/refresh-device.sh"

  HOME="$tmp/home" \
  IOS_DEVICE_ID="device-id" \
  IOS_REFRESH_NOW_EPOCH=100100 \
  IOS_REFRESH_SUCCESS_INTERVAL_SECONDS=172800 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  IOS_REFRESH_PROFILE_STATE_FILE="$tmp/profile-state" \
  IOS_REFRESH_SCRIPT="$tmp/refresh-device.sh" \
  REFRESH_CALLED_FILE="$tmp/refresh-called" \
    "$tmp/repo/ios/refresh-if-due.sh"

  if [ -e "$tmp/refresh-called" ]; then
    fail "a successful refresh less than 48 hours ago should not reinstall"
  fi
}

test_profile_expiry_overrides_recent_success() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home" "$tmp/bin"
  cp "$ROOT/ios/refresh-if-due.sh" "$tmp/repo/ios/refresh-if-due.sh"
  chmod +x "$tmp/repo/ios/refresh-if-due.sh"
  printf '100000\n' > "$tmp/last-success"
  cat > "$tmp/profile-state" <<'STATE'
profile_uuid=expiring-profile
profile_expiration_epoch=200100
last_success_epoch=100000
STATE

  cat > "$tmp/refresh-device.sh" <<'STUB'
#!/bin/sh
printf 'force=%s\n' "${IOS_FORCE_PROFILE_RENEWAL:-0}" > "$REFRESH_CALLED_FILE"
STUB
  chmod +x "$tmp/refresh-device.sh"

  write_xcrun_device_stub "$tmp/bin"

  HOME="$tmp/home" \
  IOS_DEVICE_ID="device-id" \
  IOS_REFRESH_NOW_EPOCH=200000 \
  IOS_REFRESH_SUCCESS_INTERVAL_SECONDS=172800 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  IOS_REFRESH_PROFILE_STATE_FILE="$tmp/profile-state" \
  IOS_PROFILE_RENEWAL_WINDOW_SECONDS=259200 \
  IOS_REFRESH_SCRIPT="$tmp/refresh-device.sh" \
  REFRESH_CALLED_FILE="$tmp/refresh-called" \
  DEVICE_TUNNEL_STATE=connected \
  XCRUN_BIN="$tmp/bin/xcrun" \
    "$tmp/repo/ios/refresh-if-due.sh"

  assert_file_equals "$tmp/refresh-called" "force=1"
}

test_missing_profile_state_forces_verified_renewal() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home" "$tmp/bin"
  cp "$ROOT/ios/refresh-if-due.sh" "$tmp/repo/ios/refresh-if-due.sh"
  chmod +x "$tmp/repo/ios/refresh-if-due.sh"
  printf '100000\n' > "$tmp/last-success"

  cat > "$tmp/refresh-device.sh" <<'STUB'
#!/bin/sh
printf 'force=%s\n' "${IOS_FORCE_PROFILE_RENEWAL:-0}" > "$REFRESH_CALLED_FILE"
STUB
  chmod +x "$tmp/refresh-device.sh"

  write_xcrun_device_stub "$tmp/bin"

  HOME="$tmp/home" \
  IOS_DEVICE_ID="device-id" \
  IOS_REFRESH_NOW_EPOCH=100100 \
  IOS_REFRESH_SUCCESS_INTERVAL_SECONDS=172800 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  IOS_REFRESH_PROFILE_STATE_FILE="$tmp/missing-profile-state" \
  IOS_PROFILE_RENEWAL_WINDOW_SECONDS=259200 \
  IOS_REFRESH_SCRIPT="$tmp/refresh-device.sh" \
  REFRESH_CALLED_FILE="$tmp/refresh-called" \
  DEVICE_TUNNEL_STATE=connected \
  XCRUN_BIN="$tmp/bin/xcrun" \
    "$tmp/repo/ios/refresh-if-due.sh"

  assert_file_equals "$tmp/refresh-called" "force=1"
}

test_due_refresh_waits_for_connected_device_before_signing() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home" "$tmp/bin"
  cp "$ROOT/ios/refresh-if-due.sh" "$tmp/repo/ios/refresh-if-due.sh"
  chmod +x "$tmp/repo/ios/refresh-if-due.sh"
  printf '100000\n' > "$tmp/last-success"
  cat > "$tmp/profile-state" <<'STATE'
profile_uuid=expiring-profile
profile_expiration_epoch=400000
last_success_epoch=100000
STATE

  cat > "$tmp/refresh-device.sh" <<'STUB'
#!/bin/sh
printf 'called\n' > "$REFRESH_CALLED_FILE"
STUB
  chmod +x "$tmp/refresh-device.sh"

  cat > "$tmp/signing-alert.sh" <<'STUB'
#!/bin/sh
printf '%s %s %s\n' "$1" "$2" "$3" > "$SIGNING_ALERT_LOG"
STUB
  chmod +x "$tmp/signing-alert.sh"

  write_xcrun_device_stub "$tmp/bin"

  set +e
  HOME="$tmp/home" \
  IOS_DEVICE_ID="device-id" \
  IOS_REFRESH_NOW_EPOCH=300000 \
  IOS_REFRESH_SUCCESS_INTERVAL_SECONDS=172800 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  IOS_REFRESH_PROFILE_STATE_FILE="$tmp/profile-state" \
  IOS_PROFILE_WARNING_SECONDS=172800 \
  IOS_PROFILE_CRITICAL_SECONDS=43200 \
  IOS_REFRESH_SCRIPT="$tmp/refresh-device.sh" \
  IOS_SIGNING_ALERT_BIN="$tmp/signing-alert.sh" \
  SIGNING_ALERT_LOG="$tmp/signing-alert.log" \
  REFRESH_CALLED_FILE="$tmp/refresh-called" \
  DEVICE_TUNNEL_STATE=unavailable \
  XCRUN_BIN="$tmp/bin/xcrun" \
  XCRUN_LOG="$tmp/xcrun.log" \
    "$tmp/repo/ios/refresh-if-due.sh"
  status=$?
  set -e

  [ "$status" -eq 75 ] || fail "an unavailable due device should return temporary failure 75, got $status"
  if [ -e "$tmp/refresh-called" ]; then
    fail "an unavailable device must not trigger a build/sign/install"
  fi
  assert_file_contains "$tmp/xcrun.log" "devicectl device info details"
  assert_file_equals "$tmp/signing-alert.log" "warning expiring-profile 400000"
}

test_failed_refresh_preserves_status_and_emits_deduplicated_alert() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home" "$tmp/bin"
  cp "$ROOT/ios/refresh-if-due.sh" "$tmp/repo/ios/refresh-if-due.sh"
  chmod +x "$tmp/repo/ios/refresh-if-due.sh"
  printf '100000\n' > "$tmp/last-success"
  cat > "$tmp/profile-state" <<'STATE'
profile_uuid=current-profile
profile_expiration_epoch=900000
last_success_epoch=100000
STATE

  cat > "$tmp/refresh-device.sh" <<'STUB'
#!/bin/sh
exit 23
STUB
  chmod +x "$tmp/refresh-device.sh"

  cat > "$tmp/signing-alert.sh" <<'STUB'
#!/bin/sh
printf '%s %s %s\n' "$1" "$2" "$3" > "$SIGNING_ALERT_LOG"
STUB
  chmod +x "$tmp/signing-alert.sh"
  write_xcrun_device_stub "$tmp/bin"

  set +e
  HOME="$tmp/home" \
  IOS_DEVICE_ID="device-id" \
  IOS_REFRESH_NOW_EPOCH=300000 \
  IOS_REFRESH_SUCCESS_INTERVAL_SECONDS=172800 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  IOS_REFRESH_PROFILE_STATE_FILE="$tmp/profile-state" \
  IOS_REFRESH_SCRIPT="$tmp/refresh-device.sh" \
  IOS_SIGNING_ALERT_BIN="$tmp/signing-alert.sh" \
  SIGNING_ALERT_LOG="$tmp/signing-alert.log" \
  DEVICE_TUNNEL_STATE=connected \
  XCRUN_BIN="$tmp/bin/xcrun" \
    "$tmp/repo/ios/refresh-if-due.sh"
  status=$?
  set -e

  [ "$status" -eq 23 ] || fail "failed refresh should preserve exit 23, got $status"
  assert_file_equals "$tmp/signing-alert.log" "failure current-profile 900000"
}

test_initial_renewal_failure_alerts_when_profile_state_is_missing() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home" "$tmp/bin"
  cp "$ROOT/ios/refresh-if-due.sh" "$tmp/repo/ios/refresh-if-due.sh"
  chmod +x "$tmp/repo/ios/refresh-if-due.sh"

  cat > "$tmp/refresh-device.sh" <<'STUB'
#!/bin/sh
exit 65
STUB
  chmod +x "$tmp/refresh-device.sh"

  cat > "$tmp/signing-alert.sh" <<'STUB'
#!/bin/sh
printf '%s %s %s\n' "$1" "$2" "$3" > "$SIGNING_ALERT_LOG"
STUB
  chmod +x "$tmp/signing-alert.sh"
  write_xcrun_device_stub "$tmp/bin"

  set +e
  HOME="$tmp/home" \
  IOS_DEVICE_ID="device-id" \
  IOS_REFRESH_NOW_EPOCH=300000 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  IOS_REFRESH_PROFILE_STATE_FILE="$tmp/missing-profile-state" \
  IOS_REFRESH_SCRIPT="$tmp/refresh-device.sh" \
  IOS_SIGNING_ALERT_BIN="$tmp/signing-alert.sh" \
  SIGNING_ALERT_LOG="$tmp/signing-alert.log" \
  DEVICE_TUNNEL_STATE=connected \
  XCRUN_BIN="$tmp/bin/xcrun" \
    "$tmp/repo/ios/refresh-if-due.sh"
  status=$?
  set -e

  [ "$status" -eq 65 ] || fail "initial renewal failure should preserve exit 65, got $status"
  assert_file_equals "$tmp/signing-alert.log" "failure unknown-profile 300000"
}

test_prepare_web_assets_starts_existing_stopped_container() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios/Pods" "$tmp/repo/dev" "$tmp/repo/client" "$tmp/bin"
  cp "$ROOT/ios/prepare-web-assets.sh" "$tmp/repo/ios/prepare-web-assets.sh"
  cp "$ROOT/ios/atomic-directory-swap.swift" "$tmp/repo/ios/atomic-directory-swap.swift"
  cp "$ROOT/ios/verify-web-assets.sh" "$tmp/repo/ios/verify-web-assets.sh"
  chmod +x "$tmp/repo/ios/prepare-web-assets.sh"
  chmod +x "$tmp/repo/ios/verify-web-assets.sh"

  cat > "$tmp/repo/dev/up.sh" <<'STUB'
#!/bin/sh
echo "up" >> "$UP_LOG"
touch "$CONTAINER_RUNNING_MARKER"
STUB
  chmod +x "$tmp/repo/dev/up.sh"

  cat > "$tmp/bin/container" <<'STUB'
#!/bin/sh
case "$1" in
  inspect)
    state="${PODS_DEV_STATE:-stopped}"
    if [ -e "$CONTAINER_RUNNING_MARKER" ]; then
      state="running"
    fi
    cat <<JSON
[
  {
    "mounts" : [
      { "destination" : "/work/client", "source" : "$CLIENT_SOURCE" }
    ],
    "status" : {
      "state" : "$state"
    }
  }
]
JSON
    ;;
  start)
    echo "$*" >> "$CONTAINER_LOG"
    touch "$CONTAINER_RUNNING_MARKER"
    ;;
  exec)
    echo "$*" >> "$CONTAINER_LOG"
    if [ ! -e "$CONTAINER_RUNNING_MARKER" ]; then
      echo "container is stopped" >&2
      exit 7
    fi
    mkdir -p "$CLIENT_DIST/assets"
    printf '<!doctype html><script src="./assets/app.js"></script>\n' > "$CLIENT_DIST/index.html"
    printf 'ok\n' > "$CLIENT_DIST/assets/app.js"
    ;;
  *)
    echo "unexpected container command: $*" >&2
    exit 99
    ;;
esac
STUB
  chmod +x "$tmp/bin/container"

  UP_LOG="$tmp/up.log" \
  CONTAINER_LOG="$tmp/container.log" \
  CONTAINER_RUNNING_MARKER="$tmp/running" \
  CLIENT_DIST="$tmp/repo/client/dist" \
  CLIENT_SOURCE="$tmp/repo/client" \
  PODS_DEV_STATE="stopped" \
  CONTAINER_BIN="$tmp/bin/container" \
  PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$tmp/repo/ios/prepare-web-assets.sh" >/dev/null

  assert_file_exists "$tmp/running"
  assert_file_contains "$tmp/container.log" "start pods-dev"
  assert_file_contains "$tmp/container.log" "npm ci"
  assert_file_contains "$tmp/container.log" "npm run build"
  assert_file_exists "$tmp/repo/ios/Pods/Web/index.html"
}

test_prepare_web_assets_recreates_stale_container_mounts() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios/Pods" "$tmp/repo/dev" "$tmp/repo/client" "$tmp/bin"
  cp "$ROOT/ios/prepare-web-assets.sh" "$tmp/repo/ios/prepare-web-assets.sh"
  cp "$ROOT/ios/atomic-directory-swap.swift" "$tmp/repo/ios/atomic-directory-swap.swift"
  cp "$ROOT/ios/verify-web-assets.sh" "$tmp/repo/ios/verify-web-assets.sh"
  chmod +x "$tmp/repo/ios/prepare-web-assets.sh"
  chmod +x "$tmp/repo/ios/verify-web-assets.sh"

  cat > "$tmp/repo/dev/up.sh" <<'STUB'
#!/bin/sh
echo "up" >> "$UP_LOG"
touch "$CONTAINER_RECREATED_MARKER"
touch "$CONTAINER_RUNNING_MARKER"
STUB
  chmod +x "$tmp/repo/dev/up.sh"

  cat > "$tmp/bin/container" <<'STUB'
#!/bin/sh
case "$1" in
  inspect)
    if [ -e "$CONTAINER_RECREATED_MARKER" ]; then
      stale=""
    else
      stale=', { "destination" : "/work/server", "source" : "'"$STALE_SOURCE"'" }'
    fi
    cat <<JSON
[
  {
    "mounts" : [
      { "destination" : "/work/client", "source" : "$CLIENT_SOURCE" }$stale
    ],
    "status" : {
      "state" : "running"
    }
  }
]
JSON
    ;;
  rm)
    echo "$*" >> "$CONTAINER_LOG"
    rm -f "$CONTAINER_RUNNING_MARKER"
    ;;
  exec)
    echo "$*" >> "$CONTAINER_LOG"
    mkdir -p "$CLIENT_DIST/assets"
    printf '<!doctype html><script src="./assets/app.js"></script>\n' > "$CLIENT_DIST/index.html"
    printf 'ok\n' > "$CLIENT_DIST/assets/app.js"
    ;;
  *)
    echo "unexpected container command: $*" >&2
    exit 99
    ;;
esac
STUB
  chmod +x "$tmp/bin/container"

  UP_LOG="$tmp/up.log" \
  CONTAINER_LOG="$tmp/container.log" \
  CONTAINER_RUNNING_MARKER="$tmp/running" \
  CONTAINER_RECREATED_MARKER="$tmp/recreated" \
  CLIENT_DIST="$tmp/repo/client/dist" \
  CLIENT_SOURCE="$tmp/repo/client" \
  STALE_SOURCE="$tmp/repo/server" \
  CONTAINER_BIN="$tmp/bin/container" \
  PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$tmp/repo/ios/prepare-web-assets.sh" >/dev/null

  assert_file_contains "$tmp/container.log" "rm -f pods-dev"
  assert_file_contains "$tmp/up.log" "up"
  assert_file_exists "$tmp/repo/ios/Pods/Web/index.html"
}

test_verify_web_assets_rejects_incomplete_and_accepts_complete_bundle() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios/Pods/Web/assets"
  cp "$ROOT/ios/verify-web-assets.sh" "$tmp/repo/ios/verify-web-assets.sh"
  chmod +x "$tmp/repo/ios/verify-web-assets.sh"

  set +e
  WEB_ASSETS_DIR="$tmp/repo/ios/Pods/Web" "$tmp/repo/ios/verify-web-assets.sh" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "missing web assets must fail the deployment gate"

  printf '<!doctype html><link rel="stylesheet" href="./assets/app.css"><script src="./assets/app.js"></script>\n' > "$tmp/repo/ios/Pods/Web/index.html"
  printf 'ok\n' > "$tmp/repo/ios/Pods/Web/assets/app.js"

  set +e
  WEB_ASSETS_DIR="$tmp/repo/ios/Pods/Web" "$tmp/repo/ios/verify-web-assets.sh" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "an index referencing a missing asset must fail the deployment gate"

  printf 'ok\n' > "$tmp/repo/ios/Pods/Web/assets/app.css"
  WEB_ASSETS_DIR="$tmp/repo/ios/Pods/Web" "$tmp/repo/ios/verify-web-assets.sh" >/dev/null
}

test_xcode_build_runs_web_asset_gate_before_copying_resources() {
  project="$ROOT/ios/Pods.xcodeproj/project.pbxproj"
  assert_file_contains "$project" "Verify Web Assets"
  assert_file_contains "$project" 'shellScript = "\"$PROJECT_DIR/verify-web-assets.sh\"";'

  phases="$(sed -n '/buildPhases = (/,/);/p' "$project" | head -n 8)"
  verify_line="$(printf '%s\n' "$phases" | grep -n 'Verify Web Assets' | cut -d: -f1)"
  resources_line="$(printf '%s\n' "$phases" | grep -n 'Resources' | cut -d: -f1)"
  [ -n "$verify_line" ] && [ -n "$resources_line" ] && [ "$verify_line" -lt "$resources_line" ] \
    || fail "the Xcode web-asset gate must run before resources are copied"
}

test_dev_up_starts_existing_stopped_container() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/dev" "$tmp/repo/client" "$tmp/bin"
  cp "$ROOT/dev/up.sh" "$tmp/repo/dev/up.sh"
  chmod +x "$tmp/repo/dev/up.sh"
  touch "$tmp/repo/dev/Dockerfile"

  cat > "$tmp/bin/container" <<'STUB'
#!/bin/sh
case "$1" in
  build)
    echo "$*" >> "$CONTAINER_LOG"
    ;;
  inspect)
    cat <<JSON
[
  {
    "mounts" : [
      { "destination" : "/work/client", "source" : "$CLIENT_SOURCE" }
    ],
    "status" : {
      "state" : "stopped"
    }
  }
]
JSON
    ;;
  start)
    echo "$*" >> "$CONTAINER_LOG"
    ;;
  run)
    echo "$*" >> "$CONTAINER_LOG"
    ;;
  *)
    echo "unexpected container command: $*" >&2
    exit 99
    ;;
esac
STUB
  chmod +x "$tmp/bin/container"

  CONTAINER_LOG="$tmp/container.log" \
  CLIENT_SOURCE="$tmp/repo/client" \
  CONTAINER_BIN="$tmp/bin/container" \
  PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$tmp/repo/dev/up.sh" >/dev/null

  assert_file_contains "$tmp/container.log" "build -t pods-dev-img"
  assert_file_contains "$tmp/container.log" "start pods-dev"
  if grep -Fq "run -d --name pods-dev" "$tmp/container.log"; then
    fail "dev/up.sh should not create a duplicate pods-dev container"
  fi
}

test_dev_up_recreates_stale_container_mounts() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/dev" "$tmp/repo/client" "$tmp/bin"
  cp "$ROOT/dev/up.sh" "$tmp/repo/dev/up.sh"
  chmod +x "$tmp/repo/dev/up.sh"
  touch "$tmp/repo/dev/Dockerfile"

  cat > "$tmp/bin/container" <<'STUB'
#!/bin/sh
case "$1" in
  build)
    echo "$*" >> "$CONTAINER_LOG"
    ;;
  inspect)
    if [ -e "$CONTAINER_RECREATED_MARKER" ]; then
      exit 1
    fi
    cat <<JSON
[
  {
    "mounts" : [
      { "destination" : "/work/client", "source" : "$CLIENT_SOURCE" },
      { "destination" : "/work/server", "source" : "$STALE_SOURCE" }
    ],
    "status" : {
      "state" : "running"
    }
  }
]
JSON
    ;;
  rm)
    echo "$*" >> "$CONTAINER_LOG"
    touch "$CONTAINER_RECREATED_MARKER"
    ;;
  run)
    echo "$*" >> "$CONTAINER_LOG"
    ;;
  start)
    echo "$*" >> "$CONTAINER_LOG"
    ;;
  *)
    echo "unexpected container command: $*" >&2
    exit 99
    ;;
esac
STUB
  chmod +x "$tmp/bin/container"

  CONTAINER_LOG="$tmp/container.log" \
  CONTAINER_RECREATED_MARKER="$tmp/recreated" \
  CLIENT_SOURCE="$tmp/repo/client" \
  STALE_SOURCE="$tmp/repo/server" \
  CONTAINER_BIN="$tmp/bin/container" \
  PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$tmp/repo/dev/up.sh" >/dev/null

  assert_file_contains "$tmp/container.log" "rm -f pods-dev"
  assert_file_contains "$tmp/container.log" "run -d --name pods-dev"
  if grep -Fq "start pods-dev" "$tmp/container.log"; then
    fail "dev/up.sh should recreate stale containers instead of starting them"
  fi
}

test_profile_metadata_reports_identity_and_expiration
test_signing_alerts_escalate_without_spamming
test_signing_reminders_follow_verified_profile_expiration
test_install_agent_generates_retrying_48_hour_refresh_plist
test_successful_refresh_records_success_time
test_forced_renewal_rejects_expiring_profile_before_install
test_forced_renewal_archives_only_expiring_matching_profile
test_unlaunchable_install_does_not_record_success
test_failed_default_ui_ready_check_does_not_record_success
test_ui_ready_verifier_requires_fresh_matching_build_marker
test_manual_refresh_checks_device_before_signing
test_due_refresh_invokes_installer
test_due_refresh_opens_available_device_tunnel
test_recent_success_skips_refresh
test_profile_expiry_overrides_recent_success
test_missing_profile_state_forces_verified_renewal
test_due_refresh_waits_for_connected_device_before_signing
test_failed_refresh_preserves_status_and_emits_deduplicated_alert
test_initial_renewal_failure_alerts_when_profile_state_is_missing
test_prepare_web_assets_starts_existing_stopped_container
test_prepare_web_assets_recreates_stale_container_mounts
test_verify_web_assets_rejects_incomplete_and_accepts_complete_bundle
test_xcode_build_runs_web_asset_gate_before_copying_resources
test_dev_up_starts_existing_stopped_container
test_dev_up_recreates_stale_container_mounts

echo "refresh automation tests passed"
