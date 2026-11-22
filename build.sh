#!/bin/zsh
# Builds CallNotes.app and installs it in /Applications.
# Signs with a "Developer ID Application" certificate if this Mac has one
# (hardened runtime + mic entitlement), else the local self-signed cert, else ad-hoc.
#   ./build.sh            dev build, installed in /Applications
#   ./build.sh --zip      … plus build/CallNotes-<v>.zip
#   ./build.sh --release  Developer ID only: notarize + staple + Gatekeeper check,
#                         then build/CallNotes-<v>.zip AND build/CallNotes.zip
#                         (notarytool profile "peripheralspeed-notary", override NOTARY_PROFILE=…)
set -e
cd "${0:A:h}"
VERSION=$(grep 'static let version' Sources/CallNotes/Version.swift | sed 's/.*"\(.*\)".*/\1/')

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/CallNotes"

# Assemble outside synced folders (sync daemons add xattrs codesign rejects).
T=$(mktemp -d /tmp/callnotes-build.XXXXXX)
APP="$T/CallNotes.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CallNotes"
[ -f Icon/AppIcon.icns ] && cp Icon/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>CallNotes</string>
  <key>CFBundleDisplayName</key><string>CallNotes</string>
  <key>CFBundleIdentifier</key><string>co.move-ment.callnotes</string>
  <key>CFBundleExecutable</key><string>CallNotes</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>CallNotes records your side of the call. Audio stays on this Mac.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>CallNotes records what the other participants say. Audio stays on this Mac.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>CallNotes reads the meeting happening now to fill in the call title and the other side's company. It never changes your calendar.</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 move-ment</string>
</dict></plist>
EOF

xattr -cr "$APP"
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
if [ -n "$IDENTITY" ]; then
  echo "signing with: $IDENTITY"
  codesign --force --options runtime --timestamp --entitlements CallNotes.entitlements --sign "$IDENTITY" "$APP"
else
  # A self-signed "CallNotes Local Signing" certificate in the login keychain
  # keeps the app's identity stable across rebuilds, so macOS keeps its
  # permissions. Without it, ad-hoc signing (permissions re-asked every build).
  LOCAL=$(security find-identity -p codesigning 2>/dev/null | grep '"CallNotes Local Signing"' | head -1 | awk '{print $2}' || true)
  if [ -n "$LOCAL" ]; then
    echo "signing with local certificate CallNotes Local Signing"
    codesign --force --entitlements CallNotes.entitlements --sign "$LOCAL" "$APP"
  else
    echo "no signing certificate – ad-hoc signing (macOS will re-ask for permissions after each rebuild)"
    codesign --force --entitlements CallNotes.entitlements --sign - "$APP"
  fi
fi

if [ "$1" = "--release" ]; then
  [ -n "$IDENTITY" ] || { echo "error: a release needs the Developer ID certificate (Chris's M1 Mac mini)" >&2; exit 1; }
  PROFILE="${NOTARY_PROFILE:-peripheralspeed-notary}"
  echo "submitting to Apple notary service…"
  ditto -c -k --keepParent "$APP" "$T/notarize.zip"
  xcrun notarytool submit "$T/notarize.zip" --keychain-profile "$PROFILE" --wait | tee "$T/notary.log"
  grep -q "status: Accepted" "$T/notary.log" || { echo "error: notarization was not accepted" >&2; exit 1; }
  xcrun stapler staple "$APP"
  spctl -a -vv "$APP" 2>&1 | grep -q "Notarized Developer ID" || { echo "error: Gatekeeper would block this build" >&2; exit 1; }
  echo "notarized and stapled."
fi

osascript -e 'tell application "CallNotes" to quit' >/dev/null 2>&1 || true
rm -rf /Applications/CallNotes.app
ditto "$APP" /Applications/CallNotes.app
if [ "$1" = "--zip" ] || [ "$1" = "--release" ]; then
  mkdir -p build && ditto -c -k --keepParent "$APP" "build/CallNotes-$VERSION.zip" && echo "wrote build/CallNotes-$VERSION.zip"
  [ "$1" = "--release" ] && cp "build/CallNotes-$VERSION.zip" build/CallNotes.zip && echo "wrote build/CallNotes.zip"
fi
rm -rf "$T"
echo "Installed /Applications/CallNotes.app (v$VERSION)"
