#!/bin/sh
# Build the dev image and start the long-lived pods-dev container.
# Mounts ONLY client/ and server/ (never .git — see CLAUDE.md).
# node_modules is a guest-only tmpfs; cargo target lives in the guest layer.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=pods-dev

container build -t pods-dev-img -f "$ROOT/dev/Dockerfile" "$ROOT/dev"

if container inspect "$NAME" >/dev/null 2>&1; then
  echo "$NAME already exists; leaving it as-is. (container rm -f $NAME to recreate)"
  exit 0
fi

# To dogfood from an iPhone on the LAN, recreate with: PUBLISH_IP=0.0.0.0 dev/up.sh
PUBLISH_IP="${PUBLISH_IP:-127.0.0.1}"

container run -d --name "$NAME" \
  --cpus 6 --memory 8g \
  -v "$ROOT/client:/work/client" \
  -v "$ROOT/server:/work/server" \
  --tmpfs /work/client/node_modules \
  -p "$PUBLISH_IP:5173:5173" \
  -p "$PUBLISH_IP:8080:8080" \
  pods-dev-img sleep infinity

echo "pods-dev up. Shell: dev/sh.sh — Checks: dev/check.sh"
