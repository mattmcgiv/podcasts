#!/bin/sh
# Copy the live iPhone Pods library into infra/library-export/.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${PODS_LIBRARY_EXPORT:-$ROOT/infra/library-export}"
DEVICE_ID="${IOS_DEVICE_ID:-}"
BUNDLE_ID="${IOS_BUNDLE_ID:-dev.mcgiv.pods}"
CONTAINER="${IOS_APP_CONTAINER:-}"
XCRUN_BIN="${XCRUN_BIN:-xcrun}"

rm -rf "$OUT"
mkdir -p "$OUT/raw" "$OUT/AdRemovalData"

copy_from_device() {
  src="$1"
  dest="$2"
  "$XCRUN_BIN" devicectl device copy from \
    --device "$DEVICE_ID" \
    --source "$src" \
    --destination "$dest" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --timeout 120
}

if [ -n "$CONTAINER" ]; then
  SUPPORT="$CONTAINER"
  if [ -d "$CONTAINER/AppData/Library/Application Support/Pods" ]; then
    SUPPORT="$CONTAINER/AppData/Library/Application Support/Pods"
  elif [ -d "$CONTAINER/Library/Application Support/Pods" ]; then
    SUPPORT="$CONTAINER/Library/Application Support/Pods"
  fi
  cp "$SUPPORT/pods.sqlite" "$OUT/raw/pods.sqlite"
  if [ -f "$SUPPORT/pods.sqlite-wal" ]; then cp "$SUPPORT/pods.sqlite-wal" "$OUT/raw/pods.sqlite-wal"; fi
  if [ -f "$SUPPORT/pods.sqlite-shm" ]; then cp "$SUPPORT/pods.sqlite-shm" "$OUT/raw/pods.sqlite-shm"; fi
  if [ -d "$SUPPORT/AdRemovalData" ]; then cp -R "$SUPPORT/AdRemovalData/." "$OUT/AdRemovalData/"; fi
else
  if [ -z "$DEVICE_ID" ]; then
    echo "error: set IOS_DEVICE_ID or IOS_APP_CONTAINER" >&2
    exit 2
  fi
  copy_from_device "Library/Application Support/Pods/pods.sqlite" "$OUT/raw/pods.sqlite" || true
  copy_from_device "Library/Application Support/Pods/pods.sqlite-wal" "$OUT/raw/pods.sqlite-wal" || true
  copy_from_device "Library/Application Support/Pods/pods.sqlite-shm" "$OUT/raw/pods.sqlite-shm" || true
  if [ ! -f "$OUT/raw/pods.sqlite" ]; then
    echo "error: could not copy pods.sqlite from the device" >&2
    exit 1
  fi
  copy_from_device "Library/Application Support/Pods/AdRemovalData" "$OUT/AdRemovalData" || true
fi

if [ ! -f "$OUT/raw/pods.sqlite" ]; then
  echo "error: pods.sqlite is missing" >&2
  exit 1
fi

sqlite3 "$OUT/raw/pods.sqlite" ".backup '$OUT/pods.sqlite'"

for table in podcasts episodes episode_state settings; do
  found="$(sqlite3 "$OUT/pods.sqlite" "SELECT name FROM sqlite_master WHERE name = '$table' LIMIT 1;")"
  if [ "$found" != "$table" ]; then
    echo "error: export is missing table $table" >&2
    exit 1
  fi
done

count="$(sqlite3 "$OUT/pods.sqlite" "SELECT COUNT(*) FROM episodes;")"
echo "exported episodes=$count to $OUT"
( cd "$OUT" && find AdRemovalData -type f | sort | xargs -n 1 shasum -a 256 2>/dev/null || true ) > "$OUT/checksums.txt"
shasum -a 256 "$OUT/pods.sqlite" >> "$OUT/checksums.txt"
echo "$count" > "$OUT/episode-count"
