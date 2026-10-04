#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
LOG="$OUT/logs"
APP="$OUT/UTUVO Peek.app"
EXT="$APP/Contents/PlugIns/UTUVOPeekPreview.appex"
mkdir -p "$LOG" "$OUT/modules" "$APP/Contents/MacOS" "$EXT/Contents/MacOS"
run() {
    local name="$1"; shift
    local code=0
    "$@" > "$LOG/$name.log" 2>&1 || code=$?
    printf '%s exit=%s\n' "$name" "$code"
    if (( code != 0 )); then return "$code"; fi
}
run 01-swift-build swift build --package-path "$ROOT" -j 2
run 02-swift-test swift test --package-path "$ROOT" -j 2
SDK="$(xcrun --sdk macosx --show-sdk-path)"
FLAGS=(-sdk "$SDK" -target arm64-apple-macosx14.0 -swift-version 5 -O -parse-as-library)
# Explicit static libraries avoid depending on SwiftPM's changing output layout.
run 03-core swiftc "${FLAGS[@]}" -emit-library -static -emit-module -module-name PeekCore \
    -emit-module-path "$OUT/modules/PeekCore.swiftmodule" -o "$OUT/modules/libPeekCore.a" "$ROOT"/Sources/PeekCore/*.swift
run 04-ui swiftc "${FLAGS[@]}" -emit-library -static -emit-module -module-name PeekUI \
    -I "$OUT/modules" -emit-module-path "$OUT/modules/PeekUI.swiftmodule" \
    -o "$OUT/modules/libPeekUI.a" "$ROOT"/Sources/PeekUI/*.swift
run 05-host swiftc "${FLAGS[@]}" -I "$OUT/modules" -module-name PeekApp \
    "$ROOT"/Sources/PeekApp/*.swift "$OUT/modules/libPeekUI.a" "$OUT/modules/libPeekCore.a" \
    -o "$APP/Contents/MacOS/PeekHost"
# Foundation exports NSExtensionMain. Use the standard extension linker
# entry point, not an empty Swift main or invented C trampoline.
run 06-extension swiftc "${FLAGS[@]}" -application-extension -I "$OUT/modules" -module-name PeekExtension \
    -Xlinker -e -Xlinker _NSExtensionMain \
    "$ROOT"/Sources/PeekExtension/*.swift "$OUT/modules/libPeekUI.a" "$OUT/modules/libPeekCore.a" \
    -o "$EXT/Contents/MacOS/UTUVOPeekPreview"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Pre-rendered Blender plates (scripts/blender/render_ui.sh); the preview only draws them.
mkdir -p "$EXT/Contents/Resources"
cp "$ROOT"/Resources/UI/*.png "$APP/Contents/Resources/"
cp "$ROOT"/Resources/UI/*.png "$EXT/Contents/Resources/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/PreviewExtension-Info.plist" "$EXT/Contents/Info.plist"
run 07-plists plutil -lint "$APP/Contents/Info.plist" "$EXT/Contents/Info.plist" "$ROOT/Resources/Preview.entitlements"
run 08-sign-extension codesign --force --sign - --timestamp=none --entitlements "$ROOT/Resources/Preview.entitlements" "$EXT"
run 09-sign-host codesign --force --sign - --timestamp=none "$APP"
run 10-verify codesign --verify --deep --strict --verbose=2 "$APP"
printf 'BUILD OK: %s\n' "$APP"
# Deliberately no installation, registration, extension enabling, LS reset,
# default association changes, or automatic launches.
