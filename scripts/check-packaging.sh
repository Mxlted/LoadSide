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

ARCHIVE="$QA_DIRECTORY/dist/LoadSide-$(cat VERSION)-macOS-universal-local.zip"
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
source scripts/build-support.sh
loadside_configure_build
printf 'not a Mach-O binary\n' > "$QA_DIRECTORY/invalid-binary"
expect_rejection 'Cannot inspect build metadata' loadside_verify_binary_sdk "$QA_DIRECTORY/invalid-binary"
echo 'Packaging guard checks passed.'
