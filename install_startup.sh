#!/bin/zsh
# Only run this yourself when you want login startup enabled.
set -eu
ROOT="${0:A:h}"
LABEL=com.tokentracker
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
PYTHON_BIN="${TOKENTRACKER_PYTHON:-python3}"
if [[ "$(uname -s)" != Darwin ]]; then
  printf '이 스크립트는 macOS 전용입니다.\n' >&2
  exit 1
fi
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  printf 'python3 또는 TOKENTRACKER_PYTHON 경로를 확인하세요.\n' >&2
  exit 1
fi
echo "자동 시작 설정을 변경합니다: $PLIST"
echo "로그인할 때 트래커가 실행됩니다. 지금 launchctl bootstrap으로도 시작합니다."
echo "기존 작업은 재등록합니다. 위젯 없이 대시보드만 백그라운드 실행하며 브라우저를 열지 않습니다."
echo "로그 폴더: $HOME/Library/Logs/TokenTracker"
echo "해제: $ROOT/uninstall_startup.sh"
"$PYTHON_BIN" -I - "$ROOT" "$PLIST" <<'PY'
import os
import plistlib
import sys
from pathlib import Path

if sys.version_info < (3, 10):
    raise SystemExit('Python 3.10 이상이 필요합니다.')
root, plist = map(Path, sys.argv[1:])
home = Path.home()
data = (Path(os.environ['TOKENTRACKER_HOME']).expanduser().resolve()
        if os.environ.get('TOKENTRACKER_HOME')
        else home / 'Library' / 'Application Support' / 'TokenTracker')
data.mkdir(parents=True, exist_ok=True)
logs = home / 'Library' / 'Logs' / 'TokenTracker'
logs.mkdir(parents=True, exist_ok=True)
plist.parent.mkdir(parents=True, exist_ok=True)
env = {'HOME': str(home), 'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
       'PYTHONIOENCODING': 'utf-8', 'TOKENTRACKER_HOME': str(data)}
for name in ('CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'GEMINI_HOME'):
    if os.environ.get(name):
        env[name] = os.environ[name]
job = {'Label': 'com.tokentracker',
       'ProgramArguments': [sys.executable, '-B', '-u', str(root / 'app.py'), '--dashboard', '--no-browser'],
       'WorkingDirectory': str(root), 'EnvironmentVariables': env, 'RunAtLoad': True,
       'ProcessType': 'Background',
       'StandardOutPath': str(logs / 'startup.log'),
       'StandardErrorPath': str(logs / 'startup-error.log')}
with plist.open('wb') as f:
    plistlib.dump(job, f)
plist.chmod(0o600)
PY
plutil -lint "$PLIST"
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL"
fi
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "등록했습니다. 로그: $HOME/Library/Logs/TokenTracker/startup*.log"
