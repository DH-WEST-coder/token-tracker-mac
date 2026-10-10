#!/bin/zsh
set -eu
LABEL=com.tokentracker
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
if [[ "$(uname -s)" != Darwin ]]; then
  printf '이 스크립트는 macOS 전용입니다.\n' >&2
  exit 1
fi
echo "자동 시작 작업을 종료하고 설정 파일을 삭제합니다: $PLIST"
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL"
fi
rm -f -- "$PLIST"
echo "자동 시작을 해제했습니다. 사용량 DB와 설정은 보존됩니다."
