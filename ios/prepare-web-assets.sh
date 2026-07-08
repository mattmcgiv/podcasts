#!/bin/sh
# Build the React UI inside pods-dev and stage it for the iOS app bundle.
set -eu
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB_DIR="$ROOT/ios/Pods/Web"
CONTAINER_BIN="${CONTAINER_BIN:-container}"

if ! command -v "$CONTAINER_BIN" >/dev/null 2>&1; then
  echo "error: Apple container CLI not found in PATH" >&2
  exit 127
fi

container_state() {
  "$CONTAINER_BIN" inspect pods-dev 2>/dev/null \
    | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

container_inspect() {
  "$CONTAINER_BIN" inspect pods-dev 2>/dev/null || true
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

INSPECT="$(container_inspect)"
if [ -n "$INSPECT" ] && ! container_mounts_are_current "$INSPECT"; then
  echo "Recreating pods-dev because its mounts do not match the project security boundary."
  "$CONTAINER_BIN" rm -f pods-dev
  INSPECT=""
fi

STATE="$(printf '%s\n' "$INSPECT" | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
if [ -z "$STATE" ]; then
  "$ROOT/dev/up.sh"
elif [ "$STATE" != "running" ]; then
  echo "Starting existing pods-dev container (state: $STATE)"
  "$CONTAINER_BIN" start pods-dev
fi

STATE="$(container_state || true)"
if [ "$STATE" != "running" ]; then
  echo "error: pods-dev is not running after startup attempt (state: ${STATE:-unknown})" >&2
  exit 1
fi

"$CONTAINER_BIN" exec -w /work/client pods-dev sh -lc 'if [ ! -x node_modules/.bin/tsc ] || [ ! -x node_modules/.bin/vite ]; then npm ci; fi; VITE_BASE=./ npm run build'

rm -rf "$WEB_DIR"
mkdir -p "$WEB_DIR"
cp -R "$ROOT/client/dist/." "$WEB_DIR/"
touch "$WEB_DIR/.gitkeep"

if grep -Eq '(src|href)="/(assets|manifest\.webmanifest|icon\.svg)' "$WEB_DIR/index.html"; then
  echo "error: staged iOS index.html contains root-relative bundle assets" >&2
  exit 1
fi

echo "Staged web assets in $WEB_DIR"
