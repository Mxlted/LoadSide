#!/bin/bash
# Local builds are explicitly labeled. Production requires notarization.
set -euo pipefail
cd "$(dirname "$0")/.."
usage() {
  echo 'Usage: scripts/package.sh --local [--skip-build] | --production' >&2
  exit 2
}
[[ $# -ge 1 && $# -le 2 ]] || usage
MODE="$1"
[[ "$MODE" == "--local" || "$MODE" == "--production" ]] || usage
SKIP_BUILD=false
if [[ $# -eq 2 ]]; then
  [[ "$2" == "--skip-build" ]] || usage
  [[ "$MODE" == "--local" ]] || { echo '--skip-build is supported only for local evaluation builds.' >&2; exit 2; }
  SKIP_BUILD=true
fi
if [[ "$MODE" == "--production" ]]; then
  : "${LOADSIDE_SIGNING_IDENTITY:?Set a Developer ID Application identity name or hash}"
  : "${LOADSIDE_NOTARY_PROFILE:?Set the name of an existing notarytool keychain profile}"
  [[ -z "$(git status --porcelain)" ]] || { echo 'Production packaging requires a clean Git checkout.' >&2; exit 1; }
fi
VERSION="$(cat VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo 'VERSION must contain a numeric release version with an optional prerelease suffix.' >&2; exit 1; }
SUFFIX=''
if [[ "$MODE" == "--local" ]]; then SUFFIX='-local'; fi
ARTIFACT="$PWD/dist/LoadSide-$VERSION-macOS-universal$SUFFIX.zip"
CHECKSUM="$ARTIFACT.sha256"
UNPACKED_ROOT="$PWD/dist/LoadSide-$VERSION-local"
# Fail before building, signing or notarizing if any final destination is already present.
for destination in "$ARTIFACT" "$CHECKSUM"; do
  [[ ! -e "$destination" && ! -L "$destination" ]] || { echo "Refusing to overwrite $destination" >&2; exit 1; }
done
if [[ "$MODE" == "--local" ]]; then
  [[ ! -e "$UNPACKED_ROOT" && ! -L "$UNPACKED_ROOT" ]] || { echo "Refusing to overwrite $UNPACKED_ROOT" >&2; exit 1; }
fi
mkdir -p build dist
STAGING="$(mktemp -d "$PWD/build/package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
if [[ "$SKIP_BUILD" == false ]]; then
  swift build -c release --arch arm64 --arch x86_64
fi
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
for executable in LoadSideApp loadside; do
  [[ -x "$BIN_DIR/$executable" ]] || { echo "Missing release executable: $executable" >&2; exit 1; }
  ARCHS="$(/usr/bin/lipo -archs "$BIN_DIR/$executable")"
  [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo 'Universal arm64 + x86_64 binaries are required.' >&2; exit 1; }
done
APP="$STAGING/LoadSide.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/LoadSideApp" "$APP/Contents/MacOS/LoadSide"
cp "$BIN_DIR/loadside" "$APP/Contents/Helpers/loadside"
cp Assets/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION%%-*}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LoadSideVersion $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LoadSideCommit $(git rev-parse HEAD)" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LoadSideBuildType ${MODE#--}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
swift scripts/make-icon.swift "$STAGING/LoadSide.iconset"
/usr/bin/iconutil -c icns "$STAGING/LoadSide.iconset" -o "$APP/Contents/Resources/LoadSide.icns"
cp README.md LICENSE "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/ThirdParty"
cp THIRD_PARTY_NOTICES.md Sources/CArchive/LICENSE Sources/CArchive/archive.h Sources/CArchive/archive_entry.h "$APP/Contents/Resources/ThirdParty/"
if [[ "$MODE" == "--production" ]]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$LOADSIDE_SIGNING_IDENTITY" "$APP/Contents/Helpers/loadside"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$LOADSIDE_SIGNING_IDENTITY" "$APP"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
  /usr/bin/ditto -c -k --keepParent "$APP" "$STAGING/notarize.zip"
  /usr/bin/xcrun notarytool submit "$STAGING/notarize.zip" --keychain-profile "$LOADSIDE_NOTARY_PROFILE" --wait --output-format plist > "$STAGING/notary.plist"
  STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' "$STAGING/notary.plist")"
  [[ "$STATUS" == 'Accepted' ]] || { echo 'Notarization was not accepted.' >&2; cat "$STAGING/notary.plist"; exit 1; }
  /usr/bin/xcrun stapler staple "$APP"
  /usr/bin/xcrun stapler validate "$APP"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
else
  /usr/bin/codesign --force --sign - "$APP/Contents/Helpers/loadside"
  /usr/bin/codesign --force --sign - "$APP"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
fi
/usr/bin/ditto -c -k --keepParent "$APP" "$STAGING/release.zip"
# Check again after potentially lengthy signing/notarization work; never overwrite a newer artifact.
for destination in "$ARTIFACT" "$CHECKSUM"; do
  [[ ! -e "$destination" && ! -L "$destination" ]] || { echo "Refusing to overwrite $destination" >&2; exit 1; }
done
if [[ "$MODE" == "--local" ]]; then
  [[ ! -e "$UNPACKED_ROOT" && ! -L "$UNPACKED_ROOT" ]] || { echo "Refusing to overwrite $UNPACKED_ROOT" >&2; exit 1; }
  mkdir "$UNPACKED_ROOT"
  /usr/bin/ditto "$APP" "$UNPACKED_ROOT/LoadSide.app"
fi
mv -n "$STAGING/release.zip" "$ARTIFACT"
[[ ! -e "$STAGING/release.zip" ]] || { echo 'Artifact destination appeared during packaging; refusing to overwrite it.' >&2; exit 1; }
(cd dist && set -o noclobber && /usr/bin/shasum -a 256 "$(basename "$ARTIFACT")" > "$(basename "$ARTIFACT").sha256")
echo "Created $ARTIFACT"
if [[ "$MODE" == "--local" ]]; then
  echo "Local app: $UNPACKED_ROOT/LoadSide.app"
  echo 'LOCAL BUILD: ad-hoc signed; not notarized or approved for public release.'
fi
