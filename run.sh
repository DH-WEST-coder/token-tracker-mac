#!/bin/zsh
# Run from any working directory; quote paths containing spaces.
set -eu
ROOT="${0:A:h}"
PYTHON_BIN="${TOKENTRACKER_PYTHON:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  printf 'Python 3.10 이상이 필요합니다. python3 경로 또는 TOKENTRACKER_PYTHON을 확인하세요.\n' >&2
  exit 1
fi
export PYTHONIOENCODING=utf-8
exec "$PYTHON_BIN" -B -u "$ROOT/app.py" "$@"
