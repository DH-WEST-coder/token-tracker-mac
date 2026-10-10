#!/bin/zsh
set -eu
ROOT="${0:A:h}"
exec "$ROOT/run.sh" --doctor "$@"
