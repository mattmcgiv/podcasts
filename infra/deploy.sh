#!/bin/sh
# Build the Linux API image and web UI on the laptop, then copy them to the VPS.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${PODS_SSH_HOST:-pods.mcgiv.dev}"
EXPORT="${PODS_LIBRARY_EXPORT:-$ROOT/infra/library-export}"

SSH_OPTS="-o BatchMode=yes -o User=root -o IdentitiesOnly=yes -o IdentityFile=$HOME/.ssh/id_ed25519.pub -o StrictHostKeyChecking=accept-new"
export RSYNC_RSH="ssh $SSH_OPTS"

ssh_host() {
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$HOST" "$@"
}

if [ ! -f "$EXPORT/pods.sqlite" ]; then
  echo "error: run infra/export-iphone-library.sh first ($EXPORT/pods.sqlite is missing)" >&2
  exit 1
fi

echo "building client in pods-dev"
"$ROOT/dev/sh.sh" sh -c "cd /work/client && npm run build"

echo "building pods-api image for linux/amd64"
docker build --platform linux/amd64 -t pods-api:local -f "$ROOT/backend/Dockerfile" "$ROOT/backend"

echo "building pods-transcribe image for linux/amd64"
docker build --platform linux/amd64 -t pods-transcribe:local -f "$ROOT/infra/transcribe/Dockerfile" "$ROOT/backend"

echo "copying files to $HOST"
ssh_host "install -d -m 700 /opt/pods /var/www/pods /var/lib/pods/data /var/lib/pods/models"
rsync -az --delete "$ROOT/infra/compose/docker-compose.yml" "$ROOT/infra/compose/Caddyfile" "$HOST:/opt/pods/"
rsync -az --delete "$ROOT/client/dist/" "$HOST:/var/www/pods/"
if ssh_host "test -f /var/lib/pods/data/pods.sqlite"; then
  echo "keeping existing /var/lib/pods/data/pods.sqlite"
else
  rsync -az "$EXPORT/pods.sqlite" "$HOST:/var/lib/pods/data/pods.sqlite"
  if [ -d "$EXPORT/AdRemovalData" ]; then
    rsync -az "$EXPORT/AdRemovalData/" "$HOST:/var/lib/pods/data/AdRemovalData/"
  fi
fi

MODEL_FILE=tdt_ctc-110m-q8_0.gguf
if ssh_host "test -f /var/lib/pods/models/$MODEL_FILE"; then
  echo "keeping existing Parakeet GGUF"
elif [ -f "$ROOT/infra/models/$MODEL_FILE" ]; then
  rsync -az "$ROOT/infra/models/$MODEL_FILE" "$HOST:/var/lib/pods/models/$MODEL_FILE"
else
  echo "warning: run infra/transcribe/fetch-model.sh, then copy $MODEL_FILE to /var/lib/pods/models/" >&2
fi

echo "loading images"
docker save pods-api:local pods-transcribe:local | gzip | ssh_host "gzip -dc | docker load"

echo "starting compose"
ssh_host "cd /opt/pods && docker compose up -d --force-recreate"

echo "deployed"
