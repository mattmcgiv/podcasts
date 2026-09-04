#!/bin/sh
# DEPRECATED as of 1 October 2026. Do not review, extend, or append to this script.
# See ios/DEPRECATED.md.
# Refuse to package an iOS app whose generated React bundle is absent or incomplete.
set -eu
echo "warning: deprecated as of 1 October 2026; do not extend this iPhone app/signing/install tooling. See ios/DEPRECATED.md." >&2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB_DIR="${WEB_ASSETS_DIR:-$ROOT/ios/Pods/Web}"
INDEX="$WEB_DIR/index.html"

if [ ! -s "$INDEX" ]; then
  echo "error: missing staged web UI: $INDEX" >&2
  echo "error: run ios/prepare-web-assets.sh before building Pods" >&2
  exit 1
fi

references="$(grep -oE '(src|href)="\./[^"]+"' "$INDEX" || true)"
if [ -z "$references" ]; then
  echo "error: $INDEX does not reference any staged web assets" >&2
  exit 1
fi

printf '%s\n' "$references" | while IFS= read -r reference; do
  relative="$(printf '%s\n' "$reference" | sed -E 's/^(src|href)="\.\/([^"]+)"$/\2/')"
  if [ ! -s "$WEB_DIR/$relative" ]; then
    echo "error: $INDEX references missing or empty asset: $relative" >&2
    exit 1
  fi
done

if ! printf '%s\n' "$references" | grep -Eq 'src="\./[^"]+\.js"'; then
  echo "error: $INDEX does not reference a staged JavaScript bundle" >&2
  exit 1
fi

echo "Verified staged web assets in $WEB_DIR"
