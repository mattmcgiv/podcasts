#!/bin/sh
# Download the 110M Q8 Parakeet GGUF onto the laptop. Do not run this on the VPS.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/infra/models/tdt_ctc-110m-q8_0.gguf"
URL="https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/tdt_ctc-110m-q8_0.gguf"
mkdir -p "$ROOT/infra/models"
if [ -f "$DEST" ]; then
  echo "already have $DEST"
  exit 0
fi
curl -L --fail --progress-bar -o "$DEST.part" "$URL"
mv "$DEST.part" "$DEST"
echo "wrote $DEST"
