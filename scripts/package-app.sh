#!/usr/bin/env bash
#
# Builds Swiftcamp for someone else's Mac: a Release build, checked to
# load nothing from outside the system and the app and to need nothing
# newer than the deployment target, signed with the hardened runtime,
# and packed in a disk image; with credentials, notarized and stapled.
#
#   scripts/package-app.sh
#       ad-hoc signed: runs here, and on another Mac only after Open Anyway
#   SIGN_IDENTITY="Developer ID Application: <Your Name> (<TEAMID>)" scripts/package-app.sh
#       signed for distribution
#   SIGN_IDENTITY="..." NOTARY_PROFILE=swiftcamp scripts/package-app.sh
#       signed, notarized and stapled: opens anywhere without a warning
#
# One-time setup for the last two: the "Developer ID Application"
# certificate in the login keychain, and notarization credentials stored
# under a profile name:
#   xcrun notarytool store-credentials swiftcamp --apple-id <apple id> \
#       --team-id <TEAMID> --password <app-specific password>
#
# Output: dist/Swiftcamp-<version>.dmg

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
DERIVED="$ROOT/build/release"
IDENTITY=${SIGN_IDENTITY:--}
MIN_MACOS=14.0

cd "$ROOT"
[[ -f Vendor/valhalla/build/src/libvalhalla.a ]] || { echo "error: run scripts/build-valhalla.sh first" >&2; exit 1; }
xcodegen generate >/dev/null

echo "== building Release"
# Unsigned here and signed below, file by file, as notarization wants;
# Xcode's automatic signing would pick a development identity.
xcodebuild -project Swiftcamp.xcodeproj -scheme Swiftcamp-macOS -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build -quiet

APP="$DERIVED/Build/Products/Release/Swiftcamp.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
echo "== Swiftcamp $VERSION ($BUILD), signing: $IDENTITY"

# ---- check: every Mach-O loads only the system and itself, and asks for
# no newer macOS than the app does. Either failure is a launch crash on
# someone else's Mac and nowhere here, which is why it is checked rather
# than trusted.
fail=0
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q Mach-O || continue
  outside=$(otool -L "$f" | tail -n +2 | awk '{print $1}' \
            | grep -v -e '^/usr/lib/' -e '^/System/' -e '^@rpath/' -e '^@executable_path/' -e '^@loader_path/' || true)
  if [[ -n "$outside" ]]; then
    echo "error: ${f#$APP/} loads from outside the system:" >&2
    echo "$outside" | sed 's/^/    /' >&2
    fail=1
  fi
  minos=$(vtool -show-build "$f" | awk '/minos/ {print $2; exit}')
  if [[ -n "$minos" ]] && [[ "$(printf '%s\n%s\n' "$minos" "$MIN_MACOS" | sort -V | tail -1)" != "$MIN_MACOS" ]]; then
    echo "error: ${f#$APP/} needs macOS $minos, the app promises $MIN_MACOS" >&2
    fail=1
  fi
done < <(find "$APP/Contents" -type f -print0)
((fail == 0)) || exit 1
echo "loads only the system, needs macOS $MIN_MACOS"

# ---- sign: nested code first, the bundle last, each with the hardened
# runtime and, for a real identity, a secure timestamp, which
# notarization requires.
opts=(--force --options runtime --sign "$IDENTITY")
[[ "$IDENTITY" != "-" ]] && opts+=(--timestamp)
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q Mach-O || continue
  [[ "$f" == "$APP/Contents/MacOS/Swiftcamp" ]] && continue
  codesign "${opts[@]}" "$f"
done < <(find "$APP/Contents" -type f -print0)
# The app's own entitlements go on the bundle, the code that asks for
# them; without the location one the locate button is silently refused.
codesign "${opts[@]}" --entitlements "$ROOT/Swiftcamp/Swiftcamp-macOS.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "signature ok"

# ---- notarize the app itself and staple its ticket, before it goes into
# the disk image. A ticket on the image alone covers the app only while
# it is checked online: copied out and opened on a Mac with no network,
# it has nothing to show. So two submissions, the app and then the
# image that holds the stapled app.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ "$IDENTITY" != "-" ]] || { echo "error: notarizing needs SIGN_IDENTITY" >&2; exit 1; }
  echo "== notarizing the app"
  ZIP=$(mktemp -d)/Swiftcamp.zip
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

# ---- the disk image: the app and a link to Applications, the shape
# every Mac download takes.
mkdir -p "$DIST"
DMG="$DIST/Swiftcamp-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Swiftcamp.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Swiftcamp $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
[[ "$IDENTITY" != "-" ]] && codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# ---- notarize and staple
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "== notarizing the disk image"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  xcrun stapler validate "$APP"
fi

echo "== $DMG ($(du -h "$DMG" | cut -f1))"
