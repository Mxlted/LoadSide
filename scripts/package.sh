#!/bin/bash
# Local builds are explicitly labeled. Production requires notarization.
set -euo pipefail
cd "$(dirname "$0")/.."
usage() {
  cat <<'EOF'
Usage: scripts/package.sh --local [--skip-build] [--archive]
       scripts/package.sh --production

Local mode replaces dist/LoadSide.app and its dist/loadside CLI link after
verification. Add --archive to also create a versioned ZIP and checksum.
Production mode requires Developer ID signing and notarization credentials;
it always rebuilds and creates a versioned ZIP and checksum without overwriting.
Both modes verify the minimum macOS and current linked SDK for every binary slice.
--skip-build refuses stale SDK metadata; rebuild normally after changing Xcode.
EOF
}
[[ $# -gt 0 ]] || { usage >&2; exit 2; }
if [[ "$1" == '--help' && $# -eq 1 ]]; then usage; exit 0; fi
MODE="$1"
shift
[[ "$MODE" == "--local" || "$MODE" == "--production" ]] || { usage >&2; exit 2; }
SKIP_BUILD=false
CREATE_ARCHIVE=false
while [[ $# -gt 0 ]]; do
  [[ "$MODE" == '--local' ]] || { echo 'Production mode does not accept local build options.' >&2; exit 2; }
  case "$1" in
    --skip-build) SKIP_BUILD=true ;;
    --archive) CREATE_ARCHIVE=true ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
if [[ "$MODE" == "--production" ]]; then
  CREATE_ARCHIVE=true
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
LOCAL_APP="$PWD/dist/LoadSide.app"
LOCAL_CLI="$PWD/dist/loadside"
# Archives are immutable; the canonical local app is replaced after verification.
if [[ "$CREATE_ARCHIVE" == true ]]; then
  for destination in "$ARTIFACT" "$CHECKSUM"; do
    [[ ! -e "$destination" && ! -L "$destination" ]] || { echo "Refusing to overwrite $destination" >&2; exit 1; }
  done
fi
[[ ! -L dist ]] || { echo 'Refusing a symlinked dist directory.' >&2; exit 1; }
if [[ "$MODE" == "--local" ]]; then
  [[ ! -L "$LOCAL_APP" ]] || { echo 'Refusing a symlinked local app destination.' >&2; exit 1; }
  if [[ -e "$LOCAL_APP" ]]; then
    [[ -d "$LOCAL_APP" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LOCAL_APP/Contents/Info.plist")" == 'app.loadside.mac' ]] || { echo 'The local app destination is not a LoadSide bundle.' >&2; exit 1; }
  fi
  if [[ -e "$LOCAL_CLI" || -L "$LOCAL_CLI" ]]; then
    [[ -L "$LOCAL_CLI" && "$(readlink "$LOCAL_CLI")" == 'LoadSide.app/Contents/Helpers/loadside' ]] || { echo 'Refusing to replace an unmanaged dist/loadside file.' >&2; exit 1; }
  fi
fi
source scripts/build-support.sh
loadside_configure_build
mkdir -p dist
STAGING="$(mktemp -d "$PWD/dist/.package.XXXXXX")"
INSTALLING_LOCAL=false
INSTALLED_LOCAL=false
cleanup() {
  local result=$?
  if [[ "$INSTALLED_LOCAL" == false ]]; then
    if [[ "$INSTALLING_LOCAL" == true ]]; then rm -rf "$LOCAL_APP"; fi
    if [[ -d "$STAGING/previous.app" ]]; then mv "$STAGING/previous.app" "$LOCAL_APP"; fi
  fi
  rm -rf "$STAGING"
  return "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "$SKIP_BUILD" == false ]]; then
  swift build -c release --arch arm64 --arch x86_64 "${LOADSIDE_SWIFT_BUILD_FLAGS[@]}"
fi
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 "${LOADSIDE_SWIFT_BUILD_FLAGS[@]}" --show-bin-path)"
for executable in LoadSideApp loadside; do
  [[ -x "$BIN_DIR/$executable" ]] || { echo "Missing release executable: $executable" >&2; exit 1; }
  ARCHS="$(/usr/bin/lipo -archs "$BIN_DIR/$executable")"
  [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo 'Universal arm64 + x86_64 binaries are required.' >&2; exit 1; }
done
APP="$STAGING/LoadSide.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/LoadSideApp" "$APP/Contents/MacOS/LoadSide"
cp "$BIN_DIR/loadside" "$APP/Contents/Helpers/loadside"
loadside_verify_binary_sdk "$APP/Contents/MacOS/LoadSide"
loadside_verify_binary_sdk "$APP/Contents/Helpers/loadside"
cp Assets/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION%%-*}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LoadSideVersion $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LoadSideCommit $(git rev-parse HEAD)" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LoadSideBuildType ${MODE#--}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
swift scripts/make-icon.swift "$STAGING/LoadSide.iconset"
/usr/bin/iconutil -c icns "$STAGING/LoadSide.iconset" -o "$APP/Contents/Resources/LoadSide.icns"
cp README.md LICENSE "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Documentation"
cp docs/COMPATIBILITY.md docs/APPROVAL_ENTITLEMENTS.md "$APP/Contents/Resources/Documentation/"
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
if [[ "$CREATE_ARCHIVE" == true ]]; then
  /usr/bin/ditto -c -k --keepParent "$APP" "$STAGING/release.zip"
  # Check again after potentially lengthy signing/notarization work.
  for destination in "$ARTIFACT" "$CHECKSUM"; do
    [[ ! -e "$destination" && ! -L "$destination" ]] || { echo "Refusing to overwrite $destination" >&2; exit 1; }
  done
  mv -n "$STAGING/release.zip" "$ARTIFACT"
  [[ ! -e "$STAGING/release.zip" ]] || { echo 'Artifact destination appeared during packaging; refusing to overwrite it.' >&2; exit 1; }
  (cd dist && set -o noclobber && /usr/bin/shasum -a 256 "$(basename "$ARTIFACT")" > "$(basename "$ARTIFACT").sha256")
  echo "Created $ARTIFACT"
fi
if [[ "$MODE" == "--local" ]]; then
  if [[ -d "$LOCAL_APP" ]]; then mv "$LOCAL_APP" "$STAGING/previous.app"; fi
  INSTALLING_LOCAL=true
  mv "$APP" "$LOCAL_APP"
  ln -s 'LoadSide.app/Contents/Helpers/loadside' "$STAGING/loadside"
  mv -f "$STAGING/loadside" "$LOCAL_CLI"
  INSTALLED_LOCAL=true
  echo "Local app: $LOCAL_APP"
  echo "Local CLI: $LOCAL_CLI"
  echo 'LOCAL BUILD: ad-hoc signed; not notarized or approved for public release.'
fi
