#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build --build-system native -c release --disable-sandbox --triple arm64-apple-macosx14.0 -Xswiftc -gnone --build-path .build-arm64
swift build --build-system native -c release --disable-sandbox --triple x86_64-apple-macosx14.0 -Xswiftc -gnone --build-path .build-x86_64
APP="../QuickDisk.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
 lipo -create .build-arm64/arm64-apple-macosx/release/QuickDisk .build-x86_64/x86_64-apple-macosx/release/QuickDisk -output "$APP/Contents/MacOS/QuickDisk"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f QuickDisk.icns ]]; then cp QuickDisk.icns "$APP/Contents/Resources/QuickDisk.icns"; fi
codesign --force --sign - --entitlements QuickDisk.entitlements "$APP"
print "Built universal arm64+x86_64: ${APP:A}"
