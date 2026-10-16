#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -ne 1 ]; then
    echo 'Usage: sh scripts/verify-media-pager.sh SIMULATOR_ID' >&2
    exit 2
fi
task_pager_root=${MEDIA_HUB_PAGER_BUILD_ROOT:-$(mktemp -d /tmp/media-hub-pager-ui.XXXXXX)}
mkdir -p "$task_pager_root"
cp Tests/MediaPagerUI/App.swift Tests/MediaPagerUI/PagerUITests.swift Tests/MediaPagerUI/project.yml "$task_pager_root/"
cp ios/PhotoHub/MediaPager.swift "$task_pager_root/MediaPager.swift"
echo "Pager UI test output: $task_pager_root"
xcodegen generate --spec "$task_pager_root/project.yml"
export CLANG_MODULE_CACHE_PATH=${CLANG_MODULE_CACHE_PATH:-/tmp/media-hub-clang-cache}
export SWIFTPM_MODULECACHE_OVERRIDE=${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/media-hub-swift-cache}
xcodebuild -project "$task_pager_root/PagerPreview.xcodeproj" -scheme PagerPreview \
    -destination "platform=iOS Simulator,id=$1" -parallel-testing-enabled NO -derivedDataPath "$task_pager_root/build" CODE_SIGNING_ALLOWED=NO test
