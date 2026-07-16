#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pods-corpus-helper.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

set +e
"$repo_root/dev/evaluate-ad-removal-corpus.sh" >"$tmp/stdout" 2>"$tmp/stderr"
status=$?
set -e

test "$status" -eq 64
grep -q 'usage: .*evaluate-ad-removal-corpus.sh CORPUS_INDEX.json' "$tmp/stderr"

echo "evaluate-ad-removal-corpus helper tests passed"
