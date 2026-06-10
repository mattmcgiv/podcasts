#!/bin/sh
# The merge gate: tests + enforced coverage on both stacks, all inside the VM.
set -eu

echo "== client: vitest + coverage (>=80% lines enforced in vite.config.ts) =="
container exec -w /work/client pods-dev npm run check

echo "== server: clippy + cargo llvm-cov (>=80% lines enforced) =="
container exec -w /work/server pods-dev cargo clippy --all-targets -- -D warnings
container exec -w /work/server pods-dev cargo llvm-cov --fail-under-lines 80

echo "All gates passed."
