#!/bin/bash
# Exercise fail-closed packaging guards without building or accessing credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -eq 1 && "$1" == '--help' ]]; then
  echo 'Usage: scripts/check-packaging.sh'
  echo 'Check packaging rejection paths in an isolated temporary directory without building.'
  exit 0
fi
if [[ $# -gt 0 ]]; then
  echo 'Usage: scripts/check-packaging.sh' >&2
  exit 2
fi
source scripts/build-support.sh
loadside_configure_build
QA_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp/}loadside-package-check.XXXXXX")"
trap 'rm -rf "$QA_DIRECTORY"' EXIT
mkdir -p "$QA_DIRECTORY/scripts" "$QA_DIRECTORY/dist"
cp scripts/package.sh "$QA_DIRECTORY/scripts/"
cp scripts/build-support.sh "$QA_DIRECTORY/scripts/"
cp VERSION "$QA_DIRECTORY/"
PACKAGE_SCRIPT="$QA_DIRECTORY/scripts/package.sh"
expect_rejection() {
  local expected="$1"
  shift
  if "$@" >"$QA_DIRECTORY/result.log" 2>&1; then
    echo "FAIL: Packaging accepted a request expected to fail: $expected" >&2
    exit 1
  fi
  [[ "$(cat "$QA_DIRECTORY/result.log")" == *"$expected"* ]] || { echo "FAIL: Missing expected packaging diagnostic: $expected" >&2; exit 1; }
}
expect_rejection 'Set a Developer ID Application identity' env -u LOADSIDE_SIGNING_IDENTITY -u LOADSIDE_NOTARY_PROFILE "$PACKAGE_SCRIPT" --production
expect_rejection 'Set the name of an existing notarytool keychain profile' env -u LOADSIDE_NOTARY_PROFILE LOADSIDE_SIGNING_IDENTITY=unused-test-identity "$PACKAGE_SCRIPT" --production
expect_rejection 'Production mode does not accept local build options' "$PACKAGE_SCRIPT" --production --skip-build
expect_rejection 'Usage:' "$PACKAGE_SCRIPT" --local --unknown

ARCHIVE="$QA_DIRECTORY/dist/LoadSide-$(cat VERSION)-macOS-arm64-local.zip"
printf 'existing archive\n' > "$ARCHIVE"
expect_rejection 'Refusing to overwrite' "$PACKAGE_SCRIPT" --local --archive --skip-build
[[ "$(cat "$ARCHIVE")" == 'existing archive' ]] || { echo 'FAIL: Existing archive changed.' >&2; exit 1; }
rm "$ARCHIVE"

ln -s "$QA_DIRECTORY/outside.app" "$QA_DIRECTORY/dist/LoadSide.app"
expect_rejection 'Refusing a symlinked local app destination' "$PACKAGE_SCRIPT" --local --skip-build
rm "$QA_DIRECTORY/dist/LoadSide.app"
printf 'unmanaged executable\n' > "$QA_DIRECTORY/dist/loadside"
expect_rejection 'Refusing to replace an unmanaged dist/loadside file' "$PACKAGE_SCRIPT" --local --skip-build
[[ "$(cat "$QA_DIRECTORY/dist/loadside")" == 'unmanaged executable' ]] || { echo 'FAIL: Unmanaged CLI changed.' >&2; exit 1; }
rm "$QA_DIRECTORY/dist/loadside"
rmdir "$QA_DIRECTORY/dist"
ln -s "$QA_DIRECTORY/outside-dist" "$QA_DIRECTORY/dist"
expect_rejection 'Refusing a symlinked dist directory' "$PACKAGE_SCRIPT" --local --skip-build
[[ ! -e "$QA_DIRECTORY/outside-dist" ]] || { echo 'FAIL: Packaging followed a destination symlink.' >&2; exit 1; }
loadside_validate_host Darwin arm64
loadside_validate_git_history false
expect_rejection 'Packaging requires complete Git history' loadside_validate_git_history true
expect_rejection 'Packaging requires complete Git history' loadside_validate_git_history ''
for version in 0.1.0 1.2.3-rc.1 1.2.3-beta-test; do
  loadside_validate_release_version "$version" || { echo "FAIL: Valid version rejected: $version" >&2; exit 1; }
done
for version in 01.2.3 1.02.3 1.2.03 1.2.3- 1.2.3-rc..1 1.2.3-rc.01 1.2.3-rc. 1.2.3+metadata; do
  if loadside_validate_release_version "$version"; then
    echo "FAIL: Invalid or unsupported version accepted: $version" >&2
    exit 1
  fi
done
printf 'new artifact\n' > "$QA_DIRECTORY/new-artifact"
loadside_publish_file "$QA_DIRECTORY/new-artifact" "$QA_DIRECTORY/published-artifact"
[[ "$QA_DIRECTORY/new-artifact" -ef "$QA_DIRECTORY/published-artifact" ]] || { echo 'FAIL: Published artifact differs from staged bytes.' >&2; exit 1; }
expect_rejection 'Cannot publish artifact without overwriting' loadside_publish_file "$QA_DIRECTORY/new-artifact" "$QA_DIRECTORY/published-artifact"
mkdir "$QA_DIRECTORY/existing-directory"
ln -s "$QA_DIRECTORY/existing-directory" "$QA_DIRECTORY/directory-symlink"
expect_rejection 'Cannot publish artifact without overwriting' loadside_publish_file "$QA_DIRECTORY/new-artifact" "$QA_DIRECTORY/existing-directory"
expect_rejection 'Cannot publish artifact without overwriting' loadside_publish_file "$QA_DIRECTORY/new-artifact" "$QA_DIRECTORY/directory-symlink"
[[ -z "$(ls -A "$QA_DIRECTORY/existing-directory")" ]] || { echo 'FAIL: Artifact publication followed a destination directory.' >&2; exit 1; }
expect_rejection 'requires Apple Silicon' loadside_validate_host Darwin x86_64
expect_rejection 'requires Apple Silicon' loadside_validate_host Linux arm64
printf 'not a Mach-O binary\n' > "$QA_DIRECTORY/invalid-binary"
expect_rejection 'Cannot inspect build metadata' loadside_verify_binary_sdk "$QA_DIRECTORY/invalid-binary"

# Minimal synthetic headers exercise the real lipo/vtool readers without compiling
# or executing code. Foreign slices here model rejected host artifacts, not IPAs.
write_uint32() {
  local value="$1" shift octal
  for shift in 0 8 16 24; do
    printf -v octal '%03o' "$(( (value >> shift) & 255 ))"
    printf '%b' "\\$octal"
  done
}
packed_version() {
  local major minor patch
  IFS=. read -r major minor patch <<< "$(loadside_normalize_version "$1")"
  echo "$(( (major << 16) | (minor << 8) | patch ))"
}
write_binary() {
  local destination="$1" cpu="$2" minimum="$3" sdk="$4" platform="$5" value
  for value in 0xfeedfacf "$cpu" 0 2 1 24 0 0 0x32 24 "$platform" "$minimum" "$sdk" 0; do
    write_uint32 "$value"
  done > "$destination"
}
MINIMUM="$(packed_version "$LOADSIDE_MINIMUM_MACOS")"
SDK="$(packed_version "$LOADSIDE_MACOS_SDK_VERSION")"
write_binary "$QA_DIRECTORY/arm64" 0x0100000c "$MINIMUM" "$SDK" 1
loadside_verify_binary_sdk "$QA_DIRECTORY/arm64"
write_binary "$QA_DIRECTORY/intel" 0x01000007 "$MINIMUM" "$SDK" 1
expect_rejection 'Only native arm64 binaries may ship' loadside_verify_binary_sdk "$QA_DIRECTORY/intel"
/usr/bin/lipo -create "$QA_DIRECTORY/arm64" "$QA_DIRECTORY/intel" -output "$QA_DIRECTORY/universal"
expect_rejection 'Only native arm64 binaries may ship' loadside_verify_binary_sdk "$QA_DIRECTORY/universal"
write_binary "$QA_DIRECTORY/wrong-minimum" 0x0100000c "$((MINIMUM + 65536))" "$SDK" 1
expect_rejection 'Incorrect arm64 build metadata' loadside_verify_binary_sdk "$QA_DIRECTORY/wrong-minimum"
write_binary "$QA_DIRECTORY/stale-sdk" 0x0100000c "$MINIMUM" "$((SDK - 65536))" 1
expect_rejection 'Incorrect arm64 build metadata' loadside_verify_binary_sdk "$QA_DIRECTORY/stale-sdk"
write_binary "$QA_DIRECTORY/wrong-platform" 0x0100000c "$MINIMUM" "$SDK" 2
expect_rejection 'Incorrect arm64 build metadata' loadside_verify_binary_sdk "$QA_DIRECTORY/wrong-platform"

mkdir -p "$QA_DIRECTORY/Fixture.app/Contents/MacOS" "$QA_DIRECTORY/Fixture.app/Contents/Helpers"
cp "$QA_DIRECTORY/arm64" "$QA_DIRECTORY/Fixture.app/Contents/MacOS/LoadSide"
cp "$QA_DIRECTORY/arm64" "$QA_DIRECTORY/Fixture.app/Contents/Helpers/loadside"
chmod +x "$QA_DIRECTORY/Fixture.app/Contents/MacOS/LoadSide" "$QA_DIRECTORY/Fixture.app/Contents/Helpers/loadside"
loadside_verify_bundle_binaries "$QA_DIRECTORY/Fixture.app"
expect_rejection 'Cannot inspect bundle binaries' loadside_verify_bundle_binaries "$QA_DIRECTORY/Missing.app"
cp "$QA_DIRECTORY/intel" "$QA_DIRECTORY/Fixture.app/Contents/Helpers/unexpected-helper"
chmod +x "$QA_DIRECTORY/Fixture.app/Contents/Helpers/unexpected-helper"
expect_rejection 'Only native arm64 binaries may ship' loadside_verify_bundle_binaries "$QA_DIRECTORY/Fixture.app"
rm "$QA_DIRECTORY/Fixture.app/Contents/Helpers/unexpected-helper"
cp "$QA_DIRECTORY/intel" "$QA_DIRECTORY/Fixture.app/Contents/Helpers/unexpected.dylib"
expect_rejection 'Only native arm64 binaries may ship' loadside_verify_bundle_binaries "$QA_DIRECTORY/Fixture.app"
echo 'Packaging guard checks passed.'
