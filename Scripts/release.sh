#!/bin/zsh
# Builds a signed, notarized DMG of Silica that opens without Gatekeeper warnings on any Mac:
#   <repo>/Distribute/Silica.<version>.dmg
# Then publish.sh uploads it to a GitHub Release and updates the Sparkle feed (appcast.xml).
#
# Usage (from anywhere):
#   ./Scripts/release.sh                    full run: archive, export, notarize app, DMG
#   DMG_ONLY=1 ./Scripts/release.sh         reuse the app already notarized in the cache
#                                                 and only rebuild, sign and notarize the DMG
#   DMG_TOOL=node ./Scripts/release.sh      choose how the DMG is made (see below)
#
# DMG_TOOL:
#   appdmg (default)  appdmg (npm) with our own window design (see below). Writes the window layout (.DS_Store)
#                     directly, without scripting Finder, so it works on Tahoe on Intel.
#   node              sindresorhus' create-dmg (npm) with its own standard design.
#
# Window design (appdmg): no background picture, so Finder's own window colour shows
# and the window follows Light and Dark mode. Scripts/dmg-arrow.swift draws a grey arrow from
# the app to Applications on a transparent PNG, made at build time.
#
# Needs, all kept OUT of this repository:
#   - a "Developer ID Application" certificate (team ER43ZD2S4U) in the login keychain
#   - notarization credentials stored once in the keychain (the app-specific password is typed
#     at the prompt, never written in a file):
#       xcrun notarytool store-credentials "notary-profile" --apple-id <your Apple ID> --team-id ER43ZD2S4U
#   - the DMG tool: npm install -g appdmg   (or npm install -g create-dmg for DMG_TOOL=node)
#
# Before each release raise MARKETING_VERSION and CURRENT_PROJECT_VERSION in the project:
# Sparkle compares the build number (CURRENT_PROJECT_VERSION).

# This script uses zsh syntax. If it was started with "sh release.sh" or "bash release.sh",
# run it again under zsh (that mismatch caused "syntax error: unexpected end of file").
[ -n "${ZSH_VERSION:-}" ] || exec /bin/zsh "$0" "$@"

set -euo pipefail

SCRIPT_DIR="${0:A:h}"            # .../Silica/Scripts
REPO_ROOT="${SCRIPT_DIR:h}"      # .../Silica (git repository root)
XCODE_DIR="$REPO_ROOT/Xcode-project" # where Silica.xcodeproj lives
APP=Silica
PROJECT="$XCODE_DIR/$APP.xcodeproj"
TEAM=ER43ZD2S4U
IDENTITY="Developer ID Application"
NOTARY_PROFILE=notary-profile
# Built outside the repository and outside synced folders (iCloud/Dropbox add extended
# attributes that make code signing fail).
WORK="$HOME/Library/Caches/SilicaRelease"
DIST="$REPO_ROOT/Distribute"
APP_PATH="$WORK/export/$APP.app"
DMG_TOOL="${DMG_TOOL:-appdmg}"
DMG_ONLY="${DMG_ONLY:-0}"

# DMG window layout, in points; icon x/y are icon centres measured from the top left.
# Icons sit high so that with Finder's path bar shown the icons and their names still fit.
WIN_W=600 WIN_H=320 ICON_SIZE=128 ICON_Y=105 APP_X=150 LINK_X=450
BG="$WORK/arrow/background.png"; BG2="$WORK/arrow/background@2x.png"

# --- Checks ---------------------------------------------------------------------------------
security find-identity -v -p codesigning | grep -q "$IDENTITY" \
  || { echo "No \"$IDENTITY\" certificate in the keychain."; exit 1; }

# Finds the DMG tool before the long build, so a missing tool fails at once.
case "$DMG_TOOL" in
  appdmg)
    # A global appdmg, or the copy that the npm create-dmg already brings with it.
    APPDMG=()
    if command -v appdmg >/dev/null; then
      APPDMG=("$(command -v appdmg)")
    elif command -v npm >/dev/null; then
      npm_root="$(npm root -g 2>/dev/null)"
      for js in "$npm_root/appdmg/bin/appdmg.js" "$npm_root/create-dmg/node_modules/appdmg/bin/appdmg.js"; do
        if [[ -f "$js" ]]; then APPDMG=(node "$js"); break; fi
      done
    fi
    (( ${#APPDMG} )) || { echo "appdmg is missing: npm install -g appdmg"; exit 1; }
    ;;
  node)
    command -v create-dmg >/dev/null && ! create-dmg --help 2>&1 | grep -q -- '--window-pos' \
      || { echo "The npm create-dmg is missing: npm install -g create-dmg"; exit 1; }
    ;;
  *) echo "Unknown DMG_TOOL=$DMG_TOOL (use appdmg or node)"; exit 1 ;;
esac

# Submits a file to Apple's notary service and fails if it isn't accepted.
notarize() {
  local file=$1 out id
  out=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json) || true
  print -r -- "$out"
  if ! print -r -- "$out" | grep -q '"status" *: *"Accepted"'; then
    id=$(print -r -- "$out" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' | head -1)
    echo "Notarization failed for $file"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
    exit 1
  fi
}

# --- Version --------------------------------------------------------------------------------
settings=$(xcodebuild -project "$PROJECT" -scheme "$APP" -configuration Release -showBuildSettings 2>/dev/null)
VERSION=$(print -r -- "$settings" | awk -F' = ' '/ MARKETING_VERSION = /{print $2; exit}')
BUILD=$(print -r -- "$settings" | awk -F' = ' '/ CURRENT_PROJECT_VERSION = /{print $2; exit}')
[[ -n "$VERSION" && -n "$BUILD" ]] || { echo "Couldn't read the version from $PROJECT"; exit 1; }
echo "==> $APP $VERSION ($BUILD), DMG made with $DMG_TOOL"
mkdir -p "$WORK" "$DIST"

if [[ "$DMG_ONLY" == 1 ]]; then
  # --- Reuse the app from the last full run ---------------------------------------------------
  [[ -d "$APP_PATH" ]] || { echo "No $APP_PATH: run once without DMG_ONLY=1."; exit 1; }
  built=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
  [[ "$built" == "$BUILD" ]] \
    || { echo "The cached app is build $built, the project is $BUILD: run without DMG_ONLY=1."; exit 1; }
  xcrun stapler validate "$APP_PATH" >/dev/null \
    || { echo "The cached app isn't notarized: run without DMG_ONLY=1."; exit 1; }
  echo "==> Reusing the notarized app in $APP_PATH"
else
  rm -rf "$WORK/export" "$WORK/$APP.xcarchive" "$WORK/$APP.zip"

  # --- Archive and export -------------------------------------------------------------------
  echo "==> Archiving a Release build"
  # DerivedData is kept between runs: publish.sh uses Sparkle's sign_update from it.
  xcodebuild archive -quiet \
    -project "$PROJECT" -scheme "$APP" -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$WORK/$APP.xcarchive" -derivedDataPath "$WORK/DerivedData" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM"

  echo "==> Exporting, signed with Developer ID"
  cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$IDENTITY</string>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -quiet \
    -archivePath "$WORK/$APP.xcarchive" \
    -exportOptionsPlist "$WORK/ExportOptions.plist" \
    -exportPath "$WORK/export"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"

  # --- Notarize the app ---------------------------------------------------------------------
  echo "==> Notarizing the app"
  ditto -c -k --keepParent "$APP_PATH" "$WORK/$APP.zip"
  notarize "$WORK/$APP.zip"
  xcrun stapler staple "$APP_PATH"
fi

# --- DMG ------------------------------------------------------------------------------------
echo "==> Building the DMG"
DMG="$DIST/$APP.$VERSION.dmg"
rm -f "$DMG"

if [[ "$DMG_TOOL" == appdmg ]]; then
  # Transparent picture holding only the arrow, drawn between the icons at icon height.
  # It covers just the top of the window (ICON_Y + 60 points) so it never adds scrolling.
  rm -rf "$WORK/arrow"
  mkdir -p "$WORK/arrow"
  gap=$(( ICON_SIZE / 2 + 30 ))
  for scale in 1 2; do
    out="$BG"; (( scale == 2 )) && out="$BG2"
    xcrun swift "$SCRIPT_DIR/dmg-arrow.swift" "$out" $WIN_W $(( ICON_Y + 60 )) \
      $(( APP_X + gap )) $(( LINK_X - gap )) $ICON_Y $scale
  done
fi

case "$DMG_TOOL" in
  appdmg)
    # Icons even about the middle of the window and level with the arrow (see WIN_W etc.).
    # appdmg picks up background@2x.png next to background.png for Retina displays.
    cat > "$WORK/appdmg.json" <<JSON
{
  "title": "$APP",
  "background": "$BG",
  "icon-size": $ICON_SIZE,
  "window": { "size": { "width": $WIN_W, "height": $WIN_H } },
  "format": "UDZO",
  "contents": [
    { "x": $APP_X, "y": $ICON_Y, "type": "file", "path": "$APP_PATH" },
    { "x": $LINK_X, "y": $ICON_Y, "type": "link", "path": "/Applications" }
  ]
}
JSON
    "${APPDMG[@]}" "$WORK/appdmg.json" "$DMG"
    ;;
  node)
    # Its own design (app icon on a disk image, standard background). We sign the DMG below.
    rm -rf "$WORK/node-dmg"
    mkdir -p "$WORK/node-dmg"
    create-dmg "$APP_PATH" "$WORK/node-dmg" --overwrite --no-code-sign --dmg-title="$APP"
    made=("$WORK"/node-dmg/*.dmg(N))
    (( ${#made} == 1 )) || { echo "create-dmg didn't leave one DMG in $WORK/node-dmg"; exit 1; }
    mv "$made[1]" "$DMG"
    ;;
esac
[[ -f "$DMG" ]] || { echo "No DMG was made at $DMG"; exit 1; }

echo "==> Signing and notarizing the DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "==> What Gatekeeper will say on another Mac"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP_PATH"
echo "==> Done: $DMG"
echo "    Next: RELEASE_NOTES=\$'First change\\nSecond change' ./Scripts/publish.sh"
