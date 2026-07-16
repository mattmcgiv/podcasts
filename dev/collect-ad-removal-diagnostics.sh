#!/bin/sh
set -eu

usage() {
    echo "usage: $0 IPHONE_EXPORT.zip [OUTPUT_DIRECTORY]" >&2
    exit 64
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage

iphone_export=$1
output_root=${2:-"$(pwd)/diagnostics"}
mac_root=${PODS_MAC_DIAGNOSTICS_ROOT:-"${HOME}/Library/Application Support/PodsSpeaker/AdRemovalDiagnostics"}
timestamp=${PODS_DIAGNOSTICS_NOW:-$(date -u +%Y%m%d-%H%M%S)}
bundle="$output_root/pods-ad-removal-diagnostics-$timestamp"

[ -f "$iphone_export" ] || {
    echo "iPhone diagnostics archive not found: $iphone_export" >&2
    exit 66
}
/usr/bin/unzip -t "$iphone_export" >/dev/null || {
    echo "iPhone diagnostics archive is not a valid ZIP: $iphone_export" >&2
    exit 65
}
[ ! -e "$bundle" ] || {
    echo "diagnostics bundle already exists: $bundle" >&2
    exit 73
}
[ -f "$mac_root/logs/ad-removal-00.jsonl" ] || {
    echo "current Pods Speaker structured log not found: $mac_root/logs/ad-removal-00.jsonl" >&2
    exit 66
}

mkdir -p "$bundle/iphone" "$bundle/mac"
cp "$iphone_export" "$bundle/iphone/$(basename "$iphone_export")"
cp "$mac_root/logs/ad-removal-00.jsonl" "$bundle/mac/ad-removal-00.jsonl"

{
    echo "Pods ad-removal diagnostics collection"
    echo "Created (UTC): $timestamp"
    echo "iPhone: exported ZIP copied without modification"
    echo "Mac: current rotating structured log copied without modification"
    echo "Join playback events using context.playbackSessionID."
    echo "This helper does not read or collect pairing credentials, stream tokens, or Podcast Index credentials."
} > "$bundle/README.txt"

echo "$bundle"
