#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ ! -x .venv/bin/python ]; then
  echo 'Run sh scripts/setup-desktop.sh first.' >&2
  exit 1
fi
sh scripts/build-mac-app.sh
open '.local/Media Hub.app' --args "$@"
