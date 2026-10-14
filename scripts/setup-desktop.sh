#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
  echo 'The desktop app now supports macOS only.' >&2
  exit 1
fi
task_python=${PHOTO_HUB_SETUP_PYTHON:-python3}
"$task_python" -c 'import sys; assert sys.version_info >= (3, 12), "Python 3.12 or newer is required"'
if [ ! -x .venv/bin/python ]; then
  "$task_python" -m venv .venv
fi
.venv/bin/python -m pip install -r local-api/requirements.lock.txt
.venv/bin/python scripts/generate-contracts.py --check
.venv/bin/python scripts/create-fixtures.py
sh scripts/build-mac-app.sh
echo 'Ready. Start with: sh scripts/start-desktop.sh'
