#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH=${CLANG_MODULE_CACHE_PATH:-/tmp/media-hub-clang-cache}
export SWIFTPM_MODULECACHE_OVERRIDE=${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/media-hub-swift-cache}
task_build=.local/native-build
swift build --disable-sandbox --scratch-path "$task_build" --product MediaHubMac
swift build --disable-sandbox --scratch-path "$task_build" --product MediaHubCrypto
task_bin=$(swift build --disable-sandbox --scratch-path "$task_build" --show-bin-path)
task_app='.local/Media Hub.app'
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp macos/Assets/AppIcon.icns "$task_app/Contents/Resources/AppIcon.icns"
cp "$task_bin/MediaHubCrypto" "$task_app/Contents/Resources/MediaHubCrypto"
codesign --force --sign - "$task_app/Contents/Resources/MediaHubCrypto"
cp "$task_bin/MediaHubMac" "$task_app/Contents/MacOS/MediaHubMac"
python3 - <<'PY'
import plistlib
from pathlib import Path
root = Path.cwd()
info = {
    'CFBundleExecutable': 'MediaHubMac', 'CFBundleIdentifier': 'personal.mediahub.mac',
    'CFBundleName': 'media-hub', 'CFBundleDisplayName': 'media-hub',
    'CFBundleIconFile': 'AppIcon.icns',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '2', 'CFBundleShortVersionString': '0.2.0',
    'LSMinimumSystemVersion': '13.0', 'NSHighResolutionCapable': True,
    'MediaHubDevelopmentRoot': str(root),
}
(root / '.local/Media Hub.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$task_app"
echo 'Built: .local/Media Hub.app (development build)'
