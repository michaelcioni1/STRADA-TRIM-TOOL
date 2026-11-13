#!/bin/bash
# Builds STRADA Trim Tool as a universal (Apple Silicon + Intel) app with an icon,
# then packages it into a drag-to-Applications .dmg installer.
#
#   bash make_dmg.sh
#
# Optional, for sharing without security warnings (needs a paid Apple Developer account):
#   DEV_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE="stradatrimtool" bash make_dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

NAME="STRADA Trim Tool"
EXE="StradaTrimTool"
VERSION="3.0"
APP="build/$NAME.app"
DMG="STRADA_Trim_Tool_$VERSION.dmg"
MIN_OS="14.0"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install Apple's Command Line Tools first:  xcode-select --install"
  exit 1
fi

rm -rf build "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

echo "1/5  Compiling for Apple Silicon…"
xcrun swiftc -parse-as-library -O -target "arm64-apple-macos$MIN_OS" StradaTrimTool.swift -o build/obj/arm64

echo "2/5  Compiling for Intel…"
if xcrun swiftc -parse-as-library -O -target "x86_64-apple-macos$MIN_OS" StradaTrimTool.swift -o build/obj/x86_64 2>build/obj/x86.log; then
  lipo -create build/obj/arm64 build/obj/x86_64 -output "$APP/Contents/MacOS/$EXE"
  echo "     Universal app (Apple Silicon + Intel)."
else
  cp build/obj/arm64 "$APP/Contents/MacOS/$EXE"
  echo "     Intel build not available here — app will run on Apple Silicon Macs only."
fi

echo "3/5  Making the app icon…"
ICONSET=build/obj/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIdentifier</key><string>com.strada.trimtool</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "4/5  Signing…"
if [ -n "${DEV_ID:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$DEV_ID" "$APP"
  echo "     Signed with: $DEV_ID"
else
  codesign --force --sign - "$APP"
  echo "     Ad-hoc signed (fine for your own Mac; see READ ME for sharing)."
fi

echo "5/5  Building the installer disk image…"
STAGE=build/dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "READ ME - First Launch.txt" "$STAGE/" 2>/dev/null || true
for attempt in 1 2 3; do
  if hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null; then break; fi
  echo "     hdiutil busy, retrying ($attempt)…"; sleep 5
done
[ -f "$DMG" ] || { echo "Could not create the disk image"; exit 1; }

if [ -n "${DEV_ID:-}" ]; then
  codesign --force --sign "$DEV_ID" "$DMG"
  if [ -n "${APPLE_ID:-}" ]; then
    echo "     Notarizing with Apple (can take a few minutes)…"
    xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" --wait
    xcrun stapler staple "$DMG"
  elif [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "     Notarizing with Apple (can take a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

echo ""
echo "Done:  $(pwd)/$DMG"
if [ -z "${CI:-}" ]; then open -R "$DMG"; fi
