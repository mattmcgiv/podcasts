#!/bin/sh
# Backend coverage via cargo-llvm-cov over the passkey-feature test suite.
# Enforces the 90% floor on lines, functions, and regions.
# Usage: dev/backend-coverage.sh [cargo-llvm-cov args...]
# Extra args pass through to the test run.
# Reports land in backend/target/llvm-cov/: html/index.html, lcov.info.
#
# Excluded: backend/src/ffi.rs, the deprecated iPhone FFI shell (see
# ios/DEPRECATED.md). It cannot be tested without the iPhone runtime and
# must not be touched.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if ! command -v cargo-llvm-cov >/dev/null 2>&1; then
  echo "error: cargo-llvm-cov not installed." >&2
  echo "Install it with: cargo install cargo-llvm-cov" >&2
  echo "It also needs: rustup component add llvm-tools-preview" >&2
  exit 1
fi

cd "$repo_root"
cargo llvm-cov --manifest-path backend/Cargo.toml --features passkey \
  --ignore-filename-regex 'ffi\.rs' \
  --fail-under-lines 90 --fail-under-functions 90 --fail-under-regions 90 \
  --html "$@"
cargo llvm-cov report --manifest-path backend/Cargo.toml --lcov \
  --ignore-filename-regex 'ffi\.rs' \
  --output-path backend/target/llvm-cov/lcov.info
cargo llvm-cov report --manifest-path backend/Cargo.toml --summary-only \
  --ignore-filename-regex 'ffi\.rs'
