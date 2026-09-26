#!/bin/sh
# The merge gate: frontend tests + enforced coverage, all inside the VM.
set -eu

echo "== client: vitest + coverage (global >=90% in vite.config.ts, per-file >=90% in scripts/check-coverage.mjs) =="
container exec -w /work/client pods-dev npm run check

echo "All gates passed."
