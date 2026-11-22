#!/bin/sh
# Builds Basil in Release mode and packs it into build/dist/Basil-<version>.dmg
# (Basil.app plus a link to /Applications). The version comes from project.yml.
#
#   scripts/build-dmg.sh
#
# Needs scripts/bootstrap.sh to have run once. Signing uses the identity from
# Config/Base.xcconfig or Config/Signing.local.xcconfig; the Dropbox app key from
# Config/Dropbox.local.xcconfig is included when it is set.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

version="$(sed -nE 's/^ *CFBundleShortVersionString: *"([^"]+)".*/\1/p' project.yml)"
build="$(sed -nE 's/^ *CFBundleVersion: *"([^"]+)".*/\1/p' project.yml)"
[ -n "$version" ] && [ -n "$build" ] || { echo "error: no version in project.yml" >&2; exit 1; }

derived="$root/build/ReleaseDerivedData"
dist="$root/build/dist"
app="$derived/Build/Products/Release/Basil.app"
dmg="$dist/Basil-$version.dmg"

if [ ! -d Vendor/libssh2/build/LibSSH2.xcframework ]; then
    echo "Vendored libraries missing, running scripts/bootstrap.sh"
    scripts/bootstrap.sh
fi

echo "Generating the Xcode project"
xcodegen generate --quiet

echo "Building Basil $version ($build), Release"
log="$root/build/release-build.log"
mkdir -p "$root/build"
if ! xcodebuild -project Basil.xcodeproj -scheme Basil -configuration Release \
        -derivedDataPath "$derived" clean build >"$log" 2>&1; then
    grep -E "error:" "$log" | grep -v DVTPlugIn | head -20 >&2 || true
    echo "error: build failed, full log in $log" >&2
    exit 1
fi

built="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
[ "$built" = "$version" ] || { echo "error: built app has version $built, expected $version" >&2; exit 1; }

echo "Checking the signature"
codesign --verify --deep --strict "$app"
codesign -dv "$app" 2>&1 | grep -E "^Authority=" | head -1 || true
key="$(/usr/libexec/PlistBuddy -c 'Print BasilDropboxAppKey' "$app/Contents/Info.plist" 2>/dev/null || true)"
if [ -n "$key" ]; then echo "Dropbox: included"; else echo "Dropbox: not included (no app key)"; fi

echo "Creating $dmg"
stage="$(mktemp -d "${TMPDIR:-/tmp}/basil-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Basil.app"
ln -s /Applications "$stage/Applications"
mkdir -p "$dist"
rm -f "$dmg"
hdiutil create -quiet -volname "Basil $version" -srcfolder "$stage" -fs HFS+ -format ULFO "$dmg"
hdiutil verify -quiet "$dmg"

echo "Done: $dmg ($(du -h "$dmg" | cut -f1 | tr -d ' '))"
