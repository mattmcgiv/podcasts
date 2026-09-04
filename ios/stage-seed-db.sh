#!/bin/sh
# DEPRECATED as of 1 October 2026. Do not review, extend, or append to this script.
# See ios/DEPRECATED.md.
# Stage a production SQLite DB as the first-run seed database for the iOS app.
set -eu
echo "warning: deprecated as of 1 October 2026; do not extend this iPhone app/signing/install tooling. See ios/DEPRECATED.md." >&2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-}"
DST="$ROOT/ios/Pods/SeedData/pods-seed.sqlite"

if [ -z "$SRC" ]; then
  echo "usage: ios/stage-seed-db.sh /path/to/pods.sqlite" >&2
  exit 2
fi

if [ ! -f "$SRC" ]; then
  echo "error: seed source does not exist: $SRC" >&2
  exit 1
fi

for table in podcasts episodes episode_state settings episodes_fts; do
  found="$(sqlite3 "$SRC" "SELECT name FROM sqlite_master WHERE name = '$table' LIMIT 1;")"
  if [ "$found" != "$table" ]; then
    echo "error: seed DB is missing required table: $table" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$DST")"
cp "$SRC" "$DST"
echo "Staged seed DB at $DST"
echo "This file is ignored by Git and is copied into Application Support only on first app launch."
