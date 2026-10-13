#!/bin/bash
# Local builds are explicitly labeled. Production requires notarization.
set -euo pipefail
cd "$(dirname "$0")/.."
usage() {
  cat <<'EOF'
Usage: scripts/package.sh --local [--skip-build | --archive | --dmg | --archive --dmg]
       scripts/package.sh --production

Local mode replaces dist/LoadSide.app and its dist/loadside CLI link after
verification. Add --archive for a ZIP, --dmg for a drag-to-Applications disk
image, or both. Each distributable includes a SHA-256 checksum.
Production mode requires Developer ID signing and notarization credentials;
it always rebuilds and creates a versioned ZIP and DMG without overwriting.
Both modes require native Apple Silicon and verify arm64-only binaries, minimum
macOS and the current linked SDK for the app and every bundled executable.
--skip-build refuses stale SDK metadata; rebuild normally after changing Xcode.
It cannot be combined with --archive or --dmg, and records binary source as unverified.
EOF
}
[[ $# -gt 0 ]] || { usage >&2; exit 2; }
if [[ "$1" == '--help' && $# -eq 1 ]]; then usage; exit 0; fi
MODE="$1"
shift
[[ "$MODE" == "--local" || "$MODE" == "--production" ]] || { usage >&2; exit 2; }
SKIP_BUILD=false
CREATE_ARCHIVE=false
CREATE_DMG=false
while [[ $# -gt 0 ]]; do
  [[ "$MODE" == '--local' ]] || { echo 'Production mode does not accept local build options.' >&2; exit 2; }
  case "$1" in
    --skip-build) SKIP_BUILD=true ;;
    --archive) CREATE_ARCHIVE=true ;;
    --dmg) CREATE_DMG=true ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
if [[ "$SKIP_BUILD" == true && ( "$CREATE_ARCHIVE" == true || "$CREATE_DMG" == true ) ]]; then
  echo '--skip-build cannot be combined with --archive or --dmg: distributable source provenance requires a build.' >&2
  exit 2
fi
source scripts/build-support.sh
loadside_require_supported_host
if [[ "$MODE" == "--production" ]]; then
  CREATE_ARCHIVE=true
  CREATE_DMG=true
  : "${LOADSIDE_SIGNING_IDENTITY:?Set a Developer ID Application identity name or hash}"
  : "${LOADSIDE_NOTARY_PROFILE:?Set the name of an existing notarytool keychain profile}"
  [[ -z "$(git status --porcelain)" ]] || { echo 'Production packaging requires a clean Git checkout.' >&2; exit 1; }
fi
VERSION="$(cat VERSION)"
loadside_validate_release_version "$VERSION" || { echo 'VERSION must contain a semantic release version with an optional prerelease suffix (for example 1.0.0 or 1.0.0-rc.1).' >&2; exit 1; }
SUFFIX=''
if [[ "$MODE" == "--local" ]]; then SUFFIX='-local'; fi
ARTIFACT="$PWD/dist/LoadSide-$VERSION-macOS-arm64$SUFFIX.zip"
CHECKSUM="$ARTIFACT.sha256"
DMG_ARTIFACT="$PWD/dist/LoadSide-$VERSION-macOS-arm64$SUFFIX.dmg"
DMG_CHECKSUM="$DMG_ARTIFACT.sha256"
LOCAL_APP="$PWD/dist/LoadSide.app"
LOCAL_CLI="$PWD/dist/loadside"
# Archives are immutable; the canonical local app is replaced after verification.
if [[ "$CREATE_ARCHIVE" == true ]]; then
  for destination in "$ARTIFACT" "$CHECKSUM"; do
    [[ ! -e "$destination" && ! -L "$destination" ]] || { echo "Refusing to overwrite $destination" >&2; exit 1; }
  done
fi
if [[ "$CREATE_DMG" == true ]]; then
  for destination in "$DMG_ARTIFACT" "$DMG_CHECKSUM"; do
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
loadside_validate_git_history "$(git rev-parse --is-shallow-repository)"
loadside_configure_build
mkdir -p dist
STAGING="$(mktemp -d "$PWD/dist/.package.XXXXXX")"
INSTALLING_LOCAL=false
INSTALLED_LOCAL=false
PUBLISH_SOURCES=()
PUBLISH_DESTINATIONS=()
DMG_MOUNT_ATTEMPTED=false
PACKAGE_COMPLETE=false
detach_dmg() {
  # Discover by our exact image path, including an attach interrupted before it
  # printed a device or mounted. Never detach an unrelated volume by its name.
  local devices device
  /usr/bin/hdiutil info -plist > "$STAGING/attached-images.plist" || return
  devices="$(python3 - "$STAGING/attached-images.plist" "$STAGING/release.dmg" <<'PY'
import os
import plistlib
import re
import sys

with open(sys.argv[1], 'rb') as stream:
    images = plistlib.load(stream).get('images', [])
for image in images:
    if os.path.realpath(image.get('image-path', '')) != os.path.realpath(sys.argv[2]):
        continue
    devices = [item.get('dev-entry', '') for item in image.get('system-entities', [])]
    disks = [device for device in devices if re.fullmatch(r'/dev/disk[0-9]+', device)]
    if not disks:
        sys.exit('Cannot identify the temporary disk image device for cleanup.')
    print('\n'.join(disks))
PY
)" || return
  if [[ -n "$devices" ]]; then
    while IFS= read -r device; do
      /usr/bin/hdiutil detach "$device" || /usr/bin/hdiutil detach -force "$device" || return
    done <<< "$devices"
  fi
  DMG_MOUNT_ATTEMPTED=false
}
cleanup() {
  local result=$? index remove_staging=true
  if [[ "$DMG_MOUNT_ATTEMPTED" == true ]] && ! detach_dmg; then
    echo "Could not detach the temporary disk image. Preserving $STAGING for manual cleanup." >&2
    remove_staging=false
    result=1
  fi
  if [[ "$PACKAGE_COMPLETE" == false ]]; then
    for ((index=0; index<${#PUBLISH_SOURCES[@]}; index++)); do
      if [[ ! -L "${PUBLISH_DESTINATIONS[index]}" && "${PUBLISH_DESTINATIONS[index]}" -ef "${PUBLISH_SOURCES[index]}" ]]; then
        rm -f "${PUBLISH_DESTINATIONS[index]}"
      fi
    done
  fi
  if [[ "$INSTALLED_LOCAL" == false ]]; then
    if [[ "$INSTALLING_LOCAL" == true ]]; then rm -rf "$LOCAL_APP"; fi
    if [[ -d "$STAGING/previous.app" ]]; then mv "$STAGING/previous.app" "$LOCAL_APP"; fi
  fi
  if [[ "$remove_staging" == true ]]; then rm -rf "$STAGING"; fi
  return "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "$SKIP_BUILD" == false ]]; then
  swift build -c release "${LOADSIDE_SWIFT_BUILD_FLAGS[@]}"
fi
BIN_DIR="$(swift build -c release "${LOADSIDE_SWIFT_BUILD_FLAGS[@]}" --show-bin-path)"
for executable in LoadSideApp loadside; do
  [[ -x "$BIN_DIR/$executable" ]] || { echo "Missing release executable: $executable" >&2; exit 1; }
done
[[ "$("$BIN_DIR/loadside" version)" == "LoadSide $VERSION" ]] || { echo 'Release CLI version does not match VERSION. Update source versions and rebuild.' >&2; exit 1; }
APP="$STAGING/LoadSide.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/LoadSideApp" "$APP/Contents/MacOS/LoadSide"
cp "$BIN_DIR/loadside" "$APP/Contents/Helpers/loadside"
cp Assets/Info.plist "$APP/Contents/Info.plist"
CHECKOUT_COMMIT="$(git rev-parse HEAD)"
SOURCE_COMMIT="$CHECKOUT_COMMIT"
if [[ "$SKIP_BUILD" == true ]]; then SOURCE_COMMIT=unverified; fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION%%-*}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LoadSideVersion $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LoadSideCommit $SOURCE_COMMIT" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LoadSideBuildType ${MODE#--}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
swift scripts/make-icon.swift "$STAGING/LoadSide.iconset"
/usr/bin/iconutil -c icns "$STAGING/LoadSide.iconset" -o "$APP/Contents/Resources/LoadSide.icns"
cp Assets/README-installed.md "$APP/Contents/Resources/README.md"
cp LICENSE "$APP/Contents/Resources/"
SOURCE_STATE=clean
if [[ -n "$(git status --porcelain)" ]]; then SOURCE_STATE=modified; fi
{
  printf 'LoadSide: %s\nBuild type: %s\n' "$VERSION" "${MODE#--}"
  if [[ "$SKIP_BUILD" == true ]]; then
    printf 'Source commit: unverified (existing binaries reused)\nSource tree: unverified\n'
    printf 'Packaging checkout: %s\nPackaging checkout state: %s\n' "$CHECKOUT_COMMIT" "$SOURCE_STATE"
  else
    printf 'Source commit: %s\nSource tree: %s\n' "$SOURCE_COMMIT" "$SOURCE_STATE"
  fi
  printf 'Architecture: arm64\nMinimum macOS: %s\nBuild SDK: %s\n' "$LOADSIDE_MINIMUM_MACOS" "$LOADSIDE_MACOS_SDK_VERSION"
  if [[ "$SKIP_BUILD" == true ]]; then printf 'Packaging toolchain (original compiler unverified):\n'; fi
  swift --version
} > "$APP/Contents/Resources/BuildInfo.txt"
mkdir -p "$APP/Contents/Resources/Documentation"
cp docs/COMPATIBILITY.md docs/APPROVAL_ENTITLEMENTS.md "$APP/Contents/Resources/Documentation/"
mkdir -p "$APP/Contents/Resources/ThirdParty"
cp THIRD_PARTY_NOTICES.md Sources/CArchive/LICENSE Sources/CArchive/archive.h Sources/CArchive/archive_entry.h "$APP/Contents/Resources/ThirdParty/"
loadside_verify_bundle_binaries "$APP"
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
  # Inspect the bytes users will extract, not just the pre-archive bundle. This
  # archive was produced above from our staged bundle; it is not an input archive.
  /usr/bin/unzip -tq "$STAGING/release.zip"
  /usr/bin/ditto -x -k "$STAGING/release.zip" "$STAGING/roundtrip"
  EXTRACTED_APP="$STAGING/roundtrip/LoadSide.app"
  loadside_verify_bundle_binaries "$EXTRACTED_APP"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP"
  [[ "$("$EXTRACTED_APP/Contents/Helpers/loadside" version)" == "LoadSide $VERSION" ]] || { echo 'Archived CLI version does not match VERSION.' >&2; exit 1; }
  if [[ "$MODE" == '--production' ]]; then
    /usr/bin/xcrun stapler validate "$EXTRACTED_APP"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$EXTRACTED_APP"
  fi
  PUBLISH_SOURCES+=("$STAGING/release.zip") PUBLISH_DESTINATIONS+=("$ARTIFACT")
fi
if [[ "$CREATE_DMG" == true ]]; then
  mkdir "$STAGING/disk-image"
  /usr/bin/ditto "$APP" "$STAGING/disk-image/LoadSide.app"
  ln -s /Applications "$STAGING/disk-image/Applications"
  # HFS+ and compressed UDIF retain compatibility with the minimum macOS.
  /usr/bin/hdiutil create -srcfolder "$STAGING/disk-image" -volname "LoadSide $VERSION" \
    -fs HFS+ -format UDZO "$STAGING/release.dmg"
  if [[ "$MODE" == '--production' ]]; then
    /usr/bin/codesign --force --timestamp --sign "$LOADSIDE_SIGNING_IDENTITY" "$STAGING/release.dmg"
    /usr/bin/codesign --verify --strict --verbose=2 "$STAGING/release.dmg"
    /usr/bin/xcrun notarytool submit "$STAGING/release.dmg" --keychain-profile "$LOADSIDE_NOTARY_PROFILE" --wait --output-format plist > "$STAGING/dmg-notary.plist"
    STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' "$STAGING/dmg-notary.plist")"
    [[ "$STATUS" == 'Accepted' ]] || { echo 'Disk image notarization was not accepted.' >&2; cat "$STAGING/dmg-notary.plist"; exit 1; }
    /usr/bin/xcrun stapler staple "$STAGING/release.dmg"
    /usr/bin/xcrun stapler validate "$STAGING/release.dmg"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$STAGING/release.dmg"
  fi
  /usr/bin/hdiutil verify "$STAGING/release.dmg"
  DMG_MOUNT="$STAGING/mounted"
  mkdir "$DMG_MOUNT"
  DMG_MOUNT_ATTEMPTED=true
  /usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$DMG_MOUNT" -plist "$STAGING/release.dmg" > "$STAGING/attach.plist"
  python3 - "$DMG_MOUNT" <<'PY'
import os
import sys

mount = sys.argv[1]
if not os.path.ismount(mount) or not os.statvfs(mount).f_flag & os.ST_RDONLY:
    sys.exit('Disk image did not mount read-only.')
PY
  [[ -L "$DMG_MOUNT/Applications" && "$(readlink "$DMG_MOUNT/Applications")" == /Applications ]] || { echo 'Disk image is missing its Applications shortcut.' >&2; exit 1; }
  MOUNTED_APP="$DMG_MOUNT/LoadSide.app"
  loadside_verify_bundle_binaries "$MOUNTED_APP"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$MOUNTED_APP"
  [[ "$("$MOUNTED_APP/Contents/Helpers/loadside" version)" == "LoadSide $VERSION" ]] || { echo 'Disk image CLI version does not match VERSION.' >&2; exit 1; }
  if [[ "$MODE" == '--production' ]]; then
    /usr/bin/xcrun stapler validate "$MOUNTED_APP"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$MOUNTED_APP"
  fi
  detach_dmg
  PUBLISH_SOURCES+=("$STAGING/release.dmg") PUBLISH_DESTINATIONS+=("$DMG_ARTIFACT")
fi
# Compute every checksum before publishing anything. Register ownership before
# each exclusive hard link so signal cleanup can identify our exact inode.
ARTIFACT_COUNT=${#PUBLISH_SOURCES[@]}
for ((index=0; index<ARTIFACT_COUNT; index++)); do
  source_file="${PUBLISH_SOURCES[index]}"
  destination="${PUBLISH_DESTINATIONS[index]}"
  DIGEST="$(/usr/bin/shasum -a 256 "$source_file")"
  printf '%s  %s\n' "${DIGEST%% *}" "$(basename "$destination")" > "$source_file.sha256"
  PUBLISH_SOURCES+=("$source_file.sha256") PUBLISH_DESTINATIONS+=("$destination.sha256")
done
for ((index=0; index<${#PUBLISH_SOURCES[@]}; index++)); do
  loadside_publish_file "${PUBLISH_SOURCES[index]}" "${PUBLISH_DESTINATIONS[index]}"
done
for ((index=0; index<ARTIFACT_COUNT; index++)); do
  destination="${PUBLISH_DESTINATIONS[index]}"
  (cd dist && /usr/bin/shasum -a 256 -c "$(basename "$destination").sha256")
  echo "Created $destination"
done
if [[ "$MODE" == "--local" ]]; then
  if [[ -d "$LOCAL_APP" ]]; then mv "$LOCAL_APP" "$STAGING/previous.app"; fi
  INSTALLING_LOCAL=true
  mv "$APP" "$LOCAL_APP"
  ln -s 'LoadSide.app/Contents/Helpers/loadside' "$STAGING/loadside"
  mv -f "$STAGING/loadside" "$LOCAL_CLI"
  INSTALLED_LOCAL=true
  echo "Local app: $LOCAL_APP"
  echo "Local CLI: $LOCAL_CLI"
  echo 'LOCAL BUILD: ad-hoc signed; not notarized or qualified for production release.'
  if [[ "$SKIP_BUILD" == true ]]; then echo 'SKIPPED BUILD: binary source commit and original compiler are unverified.'; fi
fi
PACKAGE_COMPLETE=true
