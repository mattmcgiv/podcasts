#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  file="$1"
  pattern="$2"
  if ! grep -Fq "$pattern" "$file"; then
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
  assert_file_contains "$plist" "<key>RunAtLoad</key>"
  assert_file_contains "$plist" "<true/>"
  assert_file_contains "$plist" "<key>PATH</key>"
  assert_file_contains "$plist" "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  assert_file_contains "$tmp/launchctl.log" "bootstrap gui/"
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

  write_xcrun_device_stub "$tmp/bin"

  HOME="$tmp/home" \
  IOS_BUILD_DIR="$tmp/build" \
  IOS_DEVICE_ID="device-id" \
  IOS_XCODE_DESTINATION="platform=iOS,id=xcode-id" \
  IOS_TEAM_ID="TEAMID" \
  IOS_SKIP_WEB_ASSETS=1 \
  IOS_REFRESH_NOW_EPOCH=12345 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  DEVICE_LIST_TUNNEL_STATE=disconnected \
  DEVICE_DETAILS_TUNNEL_STATE=connected \
  XCODEBUILD_BIN="$tmp/bin/xcodebuild" \
  XCODEBUILD_LOG="$tmp/xcodebuild.log" \
  XCRUN_BIN="$tmp/bin/xcrun" \
  XCRUN_LOG="$tmp/xcrun.log" \
    "$tmp/repo/ios/refresh-device.sh"

  assert_file_equals "$tmp/last-success" "12345"
  assert_file_contains "$tmp/xcrun.log" "devicectl device install app --device device-id"
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
  IOS_REFRESH_SCRIPT="$tmp/refresh-device.sh" \
  REFRESH_CALLED_FILE="$tmp/refresh-called" \
    "$tmp/repo/ios/refresh-if-due.sh"

  if [ -e "$tmp/refresh-called" ]; then
    fail "a successful refresh less than 48 hours ago should not reinstall"
  fi
}

test_due_refresh_waits_for_connected_device_before_signing() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/home" "$tmp/bin"
  cp "$ROOT/ios/refresh-if-due.sh" "$tmp/repo/ios/refresh-if-due.sh"
  chmod +x "$tmp/repo/ios/refresh-if-due.sh"
  printf '100000\n' > "$tmp/last-success"

  cat > "$tmp/refresh-device.sh" <<'STUB'
#!/bin/sh
printf 'called\n' > "$REFRESH_CALLED_FILE"
STUB
  chmod +x "$tmp/refresh-device.sh"

  write_xcrun_device_stub "$tmp/bin"

  set +e
  HOME="$tmp/home" \
  IOS_DEVICE_ID="device-id" \
  IOS_REFRESH_NOW_EPOCH=300000 \
  IOS_REFRESH_SUCCESS_INTERVAL_SECONDS=172800 \
  IOS_REFRESH_SUCCESS_FILE="$tmp/last-success" \
  IOS_REFRESH_SCRIPT="$tmp/refresh-device.sh" \
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
}

test_prepare_web_assets_starts_existing_stopped_container() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/repo/ios" "$tmp/repo/dev" "$tmp/repo/client" "$tmp/bin"
  cp "$ROOT/ios/prepare-web-assets.sh" "$tmp/repo/ios/prepare-web-assets.sh"
  chmod +x "$tmp/repo/ios/prepare-web-assets.sh"

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
  mkdir -p "$tmp/repo/ios" "$tmp/repo/dev" "$tmp/repo/client" "$tmp/bin"
  cp "$ROOT/ios/prepare-web-assets.sh" "$tmp/repo/ios/prepare-web-assets.sh"
  chmod +x "$tmp/repo/ios/prepare-web-assets.sh"

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

test_install_agent_generates_retrying_48_hour_refresh_plist
test_successful_refresh_records_success_time
test_unlaunchable_install_does_not_record_success
test_manual_refresh_checks_device_before_signing
test_due_refresh_invokes_installer
test_due_refresh_opens_available_device_tunnel
test_recent_success_skips_refresh
test_due_refresh_waits_for_connected_device_before_signing
test_prepare_web_assets_starts_existing_stopped_container
test_prepare_web_assets_recreates_stale_container_mounts
test_dev_up_starts_existing_stopped_container
test_dev_up_recreates_stale_container_mounts

echo "refresh automation tests passed"
