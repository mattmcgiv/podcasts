#!/bin/sh
# Exec into the pods-dev container: dev/sh.sh [cmd...] (interactive shell if no args)
set -eu
if [ $# -eq 0 ]; then
  exec container exec -it pods-dev bash
fi
exec container exec pods-dev "$@"
