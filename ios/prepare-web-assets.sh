#!/bin/sh
# Build the React UI inside pods-dev and stage it for the iOS app bundle.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB_DIR="$ROOT/ios/Pods/Web"

if ! container inspect pods-dev >/dev/null 2>&1; then
  "$ROOT/dev/up.sh"
fi

container exec -w /work/client pods-dev sh -lc 'VITE_BASE=./ npm run build'

rm -rf "$WEB_DIR"
mkdir -p "$WEB_DIR"
cp -R "$ROOT/client/dist/." "$WEB_DIR/"
touch "$WEB_DIR/.gitkeep"

if grep -Eq '(src|href)="/(assets|manifest\.webmanifest|icon\.svg)' "$WEB_DIR/index.html"; then
  echo "error: staged iOS index.html contains root-relative bundle assets" >&2
  exit 1
fi

echo "Staged web assets in $WEB_DIR"
