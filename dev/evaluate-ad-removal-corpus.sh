#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: evaluate-ad-removal-corpus.sh CORPUS_INDEX.json" >&2
    exit 64
fi

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pods-corpus-evaluator.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

cp "$repo_root/dev/ad-removal-corpus-main.swift" "$tmp/main.swift"
xcrun --sdk macosx swiftc \
    "$repo_root/ios/Pods/AdRemovalEvaluation.swift" \
    "$tmp/main.swift" \
    -o "$tmp/evaluate-ad-removal-corpus"

"$tmp/evaluate-ad-removal-corpus" "$1"
