#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
.venv/bin/python scripts/generate-contracts.py --check
.venv/bin/python scripts/verify.py
sh scripts/build-mac-app.sh
.venv/bin/python -m unittest discover -s local-api/tests -v
.venv/bin/python -m unittest discover -s backend/tests -v
export CLANG_MODULE_CACHE_PATH=${CLANG_MODULE_CACHE_PATH:-/tmp/media-hub-clang-cache}
export SWIFTPM_MODULECACHE_OVERRIDE=${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/media-hub-swift-cache}
swift test --disable-sandbox --scratch-path .local/native-build
sh scripts/build-mac-app.sh
git diff --check
