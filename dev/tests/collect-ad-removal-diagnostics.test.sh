#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pods-diagnostics-helper.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

mkdir -p "$tmp/iphone-source" "$tmp/mac/logs" "$tmp/output"
printf '%s\n' '{"formatVersion":1}' > "$tmp/iphone-source/manifest.json"
(cd "$tmp/iphone-source" && /usr/bin/zip -q "$tmp/iphone-export.zip" manifest.json)
printf '%s\n' '{"eventName":"mac_playback_event"}' > "$tmp/mac/logs/ad-removal-00.jsonl"

PODS_MAC_DIAGNOSTICS_ROOT="$tmp/mac" \
PODS_DIAGNOSTICS_NOW="20260716-120000" \
    "$repo_root/dev/collect-ad-removal-diagnostics.sh" "$tmp/iphone-export.zip" "$tmp/output"

bundle="$tmp/output/pods-ad-removal-diagnostics-20260716-120000"
test -f "$bundle/iphone/iphone-export.zip"
test -f "$bundle/mac/ad-removal-00.jsonl"
test -f "$bundle/README.txt"
/usr/bin/unzip -t "$bundle/iphone/iphone-export.zip" >/dev/null
grep -q 'mac_playback_event' "$bundle/mac/ad-removal-00.jsonl"

echo "collect-ad-removal-diagnostics tests passed"
