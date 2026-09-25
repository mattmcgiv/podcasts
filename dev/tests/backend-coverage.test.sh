#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pods-backend-coverage-helper.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# cargo-llvm-cov lives in ~/.cargo/bin, so a bare system PATH hides it.
set +e
PATH=/usr/bin:/bin "$repo_root/dev/backend-coverage.sh" >"$tmp/stdout" 2>"$tmp/stderr"
status=$?
set -e

test "$status" -eq 1
grep -q 'cargo-llvm-cov not installed' "$tmp/stderr"
grep -q 'cargo install cargo-llvm-cov' "$tmp/stderr"

echo "backend-coverage helper tests passed"
