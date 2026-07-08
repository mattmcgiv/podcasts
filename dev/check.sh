#!/bin/sh
# The merge gate: frontend tests + enforced coverage, all inside the VM.
set -eu

echo "== client: vitest + coverage (>=80% lines enforced in vite.config.ts) =="
container exec -w /work/client pods-dev npm run check

echo "All gates passed."
