#!/bin/sh
# DEPRECATED as of 1 October 2026. Do not review, extend, or append to this script.
# See ios/DEPRECATED.md.
# Build the React UI inside pods-dev and stage it for the iOS app bundle.
set -eu
echo "warning: deprecated as of 1 October 2026; do not extend this iPhone app/signing/install tooling. See ios/DEPRECATED.md." >&2
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB_DIR="$ROOT/ios/Pods/Web"
CONTAINER_BIN="${CONTAINER_BIN:-container}"
ATOMIC_SWAP_BIN="${ATOMIC_SWAP_BIN:-}"
STAGE_DIR=""

cleanup_asset_swap() {
  status=$?
  trap - EXIT HUP INT TERM

  if [ -n "$STAGE_DIR" ] && { [ -e "$STAGE_DIR" ] || [ -L "$STAGE_DIR" ]; }; then
    rm -rf "$STAGE_DIR"
  fi
  exit "$status"
}

trap cleanup_asset_swap EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

atomic_activate_directory() {
  if [ -n "$ATOMIC_SWAP_BIN" ]; then
    "$ATOMIC_SWAP_BIN" "$1" "$2"
  else
    xcrun swift "$ROOT/ios/atomic-directory-swap.swift" "$1" "$2"
  fi
}

validate_web_asset_graph() {
  asset_root="$1"
  index="$asset_root/index.html"
  if [ ! -f "$index" ]; then
    echo "error: staged iOS web assets are missing index.html" >&2
    return 1
  fi

  symbolic_link="$(find "$asset_root" -type l -print | sed -n '1p')"
  if [ -n "$symbolic_link" ]; then
    echo "error: staged iOS web assets contain a symbolic link: $symbolic_link" >&2
    return 1
  fi

  if grep -Eq '(src|href)="/(assets|manifest\.webmanifest|icon\.svg)' "$index"; then
    echo "error: staged iOS index.html contains root-relative bundle assets" >&2
    return 1
  fi

  references="$(
    grep -Eio "(src|href)[[:space:]]*=[[:space:]]*\"[^\"]*\"|(src|href)[[:space:]]*=[[:space:]]*'[^']*'" "$index" \
      || true
  )"
  while IFS= read -r attribute; do
    [ -n "$attribute" ] || continue
    reference="${attribute#*=}"
    reference="$(printf '%s' "$reference" | sed 's/^[[:space:]]*//')"
    reference="${reference#?}"
    reference="${reference%?}"
    case "$reference" in
      ''|'#'*|'//'*|[A-Za-z]*:*) continue ;;
    esac

    relative_path="${reference%%\?*}"
    relative_path="${relative_path%%\#*}"
    relative_path="${relative_path#./}"
    relative_path="${relative_path#/}"
    [ -n "$relative_path" ] || continue
    case "/$relative_path/" in
      *'/../'*|*'/./'*)
        echo "error: staged iOS index.html has invalid referenced asset: $reference" >&2
        return 1
        ;;
    esac
    if [ ! -f "$asset_root/$relative_path" ]; then
      echo "error: staged iOS index.html has missing referenced asset: $reference" >&2
      return 1
    fi
  done <<EOF
$references
EOF
}

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

validate_web_asset_graph "$ROOT/client/dist"

STAGE_DIR="$(mktemp -d "$ROOT/ios/Pods/.Web.stage.XXXXXX")"
cp -R "$ROOT/client/dist/." "$STAGE_DIR/"
touch "$STAGE_DIR/.gitkeep"
validate_web_asset_graph "$STAGE_DIR"

if atomic_activate_directory "$STAGE_DIR" "$WEB_DIR"; then
  :
else
  status=$?
  echo "error: could not atomically activate staged iOS web assets" >&2
  exit "$status"
fi

rm -rf "$STAGE_DIR"
STAGE_DIR=""
"$ROOT/ios/verify-web-assets.sh"

echo "Staged web assets in $WEB_DIR"
