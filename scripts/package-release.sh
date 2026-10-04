#!/bin/zsh
# Build, Developer ID sign (hardened runtime), notarize and staple the app and a DMG.
# Credentials stay in the Keychain: SIGNING_IDENTITY names a Developer ID Application identity,
# NOTARY_PROFILE an existing `notarytool store-credentials` profile. Nothing is published.
set -euo pipefail

cd "${0:A:h:h}"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool Keychain profile}"
[[ "$(uname -m)" == arm64 ]] || { print -u2 'Release target is Apple Silicon.'; exit 1; }

bash scripts/build.sh
APP_SOURCE="build/UTUVO Peek.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SOURCE/Contents/Info.plist")
OUTPUT="$PWD/build/distribution/$VERSION"
STEM="UTUVO-Peek-$VERSION-arm64"
[[ ! -e "$OUTPUT/$STEM.dmg" ]] || { print -u2 'Release DMG already exists; use a new version or preserve this release.'; exit 1; }
rm -rf "$OUTPUT/work"; mkdir -p "$OUTPUT/work/content"

APP="$OUTPUT/work/UTUVO Peek.app"
EXT="$APP/Contents/PlugIns/UTUVOPeekPreview.appex"
ditto "$APP_SOURCE" "$APP"
for bin in "$APP/Contents/MacOS/PeekHost" "$EXT/Contents/MacOS/UTUVOPeekPreview"; do lipo "$bin" -verify_arch arm64; done
# Inside out: the sandboxed extension keeps its entitlements, then the host seals it.
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
  --entitlements Resources/Preview.entitlements "$EXT"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$2"
  /usr/bin/python3 - "$2" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print('Apple notarization:', result.get('id'), result.get('status'))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted; inspect the saved result.')
PY
}

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/work/app-submission.zip"
notarize "$OUTPUT/work/app-submission.zip" "$OUTPUT/app-notarization.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ditto "$APP" "$OUTPUT/work/content/UTUVO Peek.app"
ln -s /Applications "$OUTPUT/work/content/Applications"
cat > "$OUTPUT/work/content/安裝說明 Install.txt" <<'TXT'
UTUVO Peek — Quick Look for audio files

1. 把 UTUVO Peek 拖到 Applications。
2. 從「應用程式」打開一次 UTUVO Peek，再關掉（這一步讓 Finder 登記預覽功能）。
3. 在 Finder 選一個音檔，按空白鍵：預覽出現就會自動播放，再按一次空白鍵關閉並停止。
   若仍是系統的預覽：系統設定 › 一般 › 登入項目與延伸功能 › Quick Look，確認 UTUVO Peek 已勾選。

1. Drag UTUVO Peek to Applications.
2. Open UTUVO Peek once from Applications, then quit it (this registers the Quick Look extension).
3. In Finder, select an audio file and press Space: the preview plays automatically; press Space again to close and stop.
   If the system preview still appears: System Settings › General › Login Items & Extensions › Quick Look, enable UTUVO Peek.

No network, no analytics. Requires macOS 14+ and Apple Silicon. MIT licensed:
https://github.com/mickyyang-1407/utuvo-peek
TXT
hdiutil create -quiet -fs HFS+ -volname 'UTUVO Peek' -srcfolder "$OUTPUT/work/content" \
  -format UDZO -imagekey zlib-level=9 "$OUTPUT/$STEM.dmg"
codesign --sign "$SIGNING_IDENTITY" --timestamp "$OUTPUT/$STEM.dmg"
codesign --verify --strict "$OUTPUT/$STEM.dmg"
notarize "$OUTPUT/$STEM.dmg" "$OUTPUT/dmg-notarization.json"
xcrun stapler staple "$OUTPUT/$STEM.dmg"
xcrun stapler validate "$OUTPUT/$STEM.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$OUTPUT/$STEM.dmg"

(cd "$OUTPUT" && shasum -a 256 "$STEM.dmg" > SHA256SUMS.txt)
print "Verified release: $OUTPUT/$STEM.dmg"
