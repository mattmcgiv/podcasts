#!/bin/sh
# Build the dev image and start the long-lived pods-dev container.
# Mounts ONLY client/ (never .git — see AGENTS.md).
# node_modules is a guest-only tmpfs.
set -eu
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=pods-dev
CONTAINER_BIN="${CONTAINER_BIN:-container}"

container_state() {
  "$CONTAINER_BIN" inspect "$NAME" 2>/dev/null \
    | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

container_inspect() {
  "$CONTAINER_BIN" inspect "$NAME" 2>/dev/null || true
}

container_mounts_are_current() {
  normalized="$(printf '%s\n' "$1" | sed 's#\\/#/#g')"
  printf '%s\n' "$normalized" | grep -Fq "\"source\" : \"$ROOT/client\"" || return 1
  if printf '%s\n' "$normalized" | grep -Fq '"destination" : "/work/server"'; then
    return 1
  fi
  if printf '%s\n' "$normalized" | grep -Fq "\"source\" : \"$ROOT\""; then
    return 1
  fi
  return 0
}

"$CONTAINER_BIN" build -t pods-dev-img -f "$ROOT/dev/Dockerfile" "$ROOT/dev"

INSPECT="$(container_inspect)"
if [ -n "$INSPECT" ] && ! container_mounts_are_current "$INSPECT"; then
  echo "$NAME mounts do not match this repo's security boundary; recreating it."
  "$CONTAINER_BIN" rm -f "$NAME"
  INSPECT=""
fi

STATE="$(printf '%s\n' "$INSPECT" | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
if [ "$STATE" = "running" ]; then
  echo "$NAME already running. (container rm -f $NAME to recreate)"
  exit 0
fi
if [ -n "$STATE" ]; then
  echo "$NAME exists with state '$STATE'; starting it. (container rm -f $NAME to recreate)"
  "$CONTAINER_BIN" start "$NAME"
  exit 0
fi

# To dogfood from an iPhone on the LAN, recreate with: PUBLISH_IP=0.0.0.0 dev/up.sh
PUBLISH_IP="${PUBLISH_IP:-127.0.0.1}"

"$CONTAINER_BIN" run -d --name "$NAME" \
  --dns "${PODS_DEV_DNS:-1.1.1.1}" \
  --cpus 6 --memory 8g \
  -v "$ROOT/client:/work/client" \
  --tmpfs /work/client/node_modules \
  -p "$PUBLISH_IP:5173:5173" \
  pods-dev-img sleep infinity

echo "pods-dev up. Shell: dev/sh.sh — Checks: dev/check.sh"
