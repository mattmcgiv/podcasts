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

make_stub_bin() {
  dir="$1"
  mkdir -p "$dir"
}

test_install_agent_generates_restart_safe_48_hour_plist() {
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
  assert_file_contains "$plist" "<integer>172800</integer>"
  assert_file_contains "$plist" "<key>RunAtLoad</key>"
  assert_file_contains "$plist" "<true/>"
  assert_file_contains "$plist" "<key>PATH</key>"
  assert_file_contains "$plist" "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  assert_file_contains "$tmp/launchctl.log" "bootstrap gui/"
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

test_install_agent_generates_restart_safe_48_hour_plist
test_prepare_web_assets_starts_existing_stopped_container
test_prepare_web_assets_recreates_stale_container_mounts
test_dev_up_starts_existing_stopped_container
test_dev_up_recreates_stale_container_mounts

echo "refresh automation tests passed"
