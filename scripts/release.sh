#!/usr/bin/env bash
#
# Builds, notarizes and publishes a Silica release:
#
#   scripts/release.sh <version> [release-notes.md]
#
#   1. bumps MARKETING_VERSION to <version> and CURRENT_PROJECT_VERSION by one
#   2. archives and exports the app signed with your Developer ID
#   3. notarizes and staples the app, packs it in a styled DMG (scripts/dmg),
#      notarizes and staples that
#   4. commits the version bump, tags v<version> and pushes both
#   5. creates the GitHub release with the DMG attached
#   6. adds the release to docs/appcast.xml (the Sparkle feed GitHub Pages serves)
#      and pushes it, which is what makes running copies offer the update
#
# Without a notes file, GitHub generates the notes from the commits since the last
# release. Either way they are also embedded in the appcast for Sparkle to show.
#
# One-time setup is in RELEASING.md.

set -euo pipefail

VERSION=${1:-}
NOTES_FILE=${2:-}
NOTARY_PROFILE=${NOTARY_PROFILE:-silica-notary}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PROJECT=Silica.xcodeproj
PROJECT_FILE=$PROJECT/project.pbxproj
SCHEME=Silica
FEED=docs/appcast.xml
TAG=v$VERSION
WORK=build/release/$VERSION
PACKAGES=build/SourcePackages
SPARKLE_BIN=$PACKAGES/artifacts/sparkle/Sparkle/bin

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

# --- Checks, before anything changes ------------------------------------------

[[ -n $VERSION ]] || die "usage: scripts/release.sh <version> [release-notes.md]"
[[ $VERSION =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "version must look like 1.2 or 1.2.0"
[[ -z $NOTES_FILE || -f $NOTES_FILE ]] || die "no such notes file: $NOTES_FILE"
[[ -z $(git status --porcelain) ]] || die "commit or stash your changes first"
[[ $(git branch --show-current) == main ]] || die "releases are made from main"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"

command -v gh >/dev/null || die "install the GitHub CLI (brew install gh) and run gh auth login"
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) \
    || die "this checkout has no GitHub repository (or gh isn't signed in)"
git fetch -q origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || die "main isn't in sync with origin/main"

grep -q 'PRODUCT_BUNDLE_IDENTIFIER = devplaceholder' "$PROJECT_FILE" \
    && die "set a real PRODUCT_BUNDLE_IDENTIFIER first; it can't change after the first release"

TEAM_ID=$(sed -n 's/.*DEVELOPMENT_TEAM = \([^;]*\);.*/\1/p' "$PROJECT_FILE" | head -1)
SIGN_IDENTITY=$(security find-identity -v -p codesigning \
    | sed -n "s/.*\"\(Developer ID Application: .*($TEAM_ID)\)\".*/\1/p" | head -1)
[[ -n $SIGN_IDENTITY ]] || die "no Developer ID Application certificate for team $TEAM_ID in your keychain"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "no notarization credentials named $NOTARY_PROFILE; see RELEASING.md"

# make-dmg.sh needs the name for the new DMG's volume.
[[ ! -e /Volumes/Silica ]] || die "eject the volume named Silica first"

# --- Version bump, undone if anything fails before it's committed --------------

OLD_BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' "$PROJECT_FILE" | head -1)
BUILD_NUMBER=$((OLD_BUILD + 1))

COMMITTED=false
restore() { $COMMITTED || git checkout -q -- "$PROJECT_FILE"; }
trap restore EXIT

step "Silica $VERSION (build $BUILD_NUMBER) for $REPO"
sed -i '' \
    -e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/" \
    -e "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/" \
    "$PROJECT_FILE"

rm -rf "$WORK"
mkdir -p "$WORK"

# --- Build ----------------------------------------------------------------------

step "Archiving"
xcodebuild archive -quiet \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$WORK/Silica.xcarchive" \
    -clonedSourcePackagesDirPath "$PACKAGES"

step "Exporting with $SIGN_IDENTITY"
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -quiet -allowProvisioningUpdates \
    -archivePath "$WORK/Silica.xcarchive" \
    -exportOptionsPlist "$WORK/ExportOptions.plist" \
    -exportPath "$WORK/export"
APP=$WORK/export/Silica.app

BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILT_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
[[ $BUILT_VERSION == "$VERSION" && $BUILT_NUMBER == "$BUILD_NUMBER" ]] \
    || die "built $BUILT_VERSION ($BUILT_NUMBER), expected $VERSION ($BUILD_NUMBER)"

# --- Notarize -------------------------------------------------------------------

# The app itself is stapled too, so it opens offline once copied out of the DMG.
step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$WORK/Silica-notarize.zip"
xcrun notarytool submit "$WORK/Silica-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

step "Packing and notarizing the DMG"
DMG=$WORK/Silica-$VERSION.dmg
scripts/dmg/make-dmg.sh "$APP" "$DMG"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"

# --- Publish --------------------------------------------------------------------

step "Tagging $TAG"
git commit -q -m "Release $VERSION" -- "$PROJECT_FILE"
COMMITTED=true
git tag -a "$TAG" -m "Silica $VERSION"
git push -q origin main "$TAG"

step "Creating the GitHub release"
if [[ -n $NOTES_FILE ]]; then
    gh release create "$TAG" "$DMG" --verify-tag --title "Silica $VERSION" --notes-file "$NOTES_FILE"
else
    gh release create "$TAG" "$DMG" --verify-tag --title "Silica $VERSION" --generate-notes
fi

# generate_appcast works on a folder of archives and keeps the items already in
# the feed, so it gets just the new DMG, its notes and the current feed.
step "Adding $VERSION to the update feed"
FEED_WORK=$WORK/appcast
mkdir "$FEED_WORK"
cp "$DMG" "$FEED_WORK/"
[[ -f $FEED ]] && cp "$FEED" "$FEED_WORK/appcast.xml"
gh release view "$TAG" --json body -q .body > "$FEED_WORK/Silica-$VERSION.md"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --embed-release-notes \
    --full-release-notes-url "https://github.com/$REPO/releases" \
    --link "https://github.com/$REPO" \
    --maximum-versions 0 \
    "$FEED_WORK"
mkdir -p "$(dirname "$FEED")"
cp "$FEED_WORK/appcast.xml" "$FEED"
git add "$FEED"
git commit -q -m "Offer $VERSION in the update feed"
git push -q origin main

step "Released Silica $VERSION"
echo "https://github.com/$REPO/releases/tag/$TAG"
echo "Running copies see it once GitHub Pages redeploys docs/ (usually within a minute)."
