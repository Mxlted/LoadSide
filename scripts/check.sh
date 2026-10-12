#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--skip-build" ) ]]; then
  echo 'Usage: scripts/check.sh [--skip-build]' >&2
  exit 2
fi
if [[ $# -eq 0 ]]; then
  swift test
  swift build -c release
fi
BIN_DIR="$(swift build -c release --show-bin-path)"
"$BIN_DIR/loadside" --help >/dev/null
"$BIN_DIR/loadside" doctor
"$BIN_DIR/loadside" version
[[ "$("$BIN_DIR/loadside" version)" == "LoadSide $(cat VERSION)" ]] || { echo 'FAIL: CLI version does not match VERSION.' >&2; exit 1; }
QA_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp/}loadside-cli-check.XXXXXX")"
trap 'rm -rf "$QA_DIRECTORY"' EXIT
printf 'invalid archive\n' > "$QA_DIRECTORY/invalid.ipa"
printf 'invalid provisioning profile\n' > "$QA_DIRECTORY/invalid.mobileprovision"
if "$BIN_DIR/loadside" profile "$QA_DIRECTORY/invalid.mobileprovision" >"$QA_DIRECTORY/profile.log" 2>&1; then
  echo 'FAIL: Invalid profile was accepted.' >&2
  exit 1
fi
if printf '\n' | "$BIN_DIR/loadside" sign --ipa "$QA_DIRECTORY/invalid.ipa" --p12 "$QA_DIRECTORY/invalid.mobileprovision" --profile "$QA_DIRECTORY/invalid.mobileprovision" --output "$QA_DIRECTORY/output.ipa" --password-stdin >"$QA_DIRECTORY/sign.log" 2>&1; then
  echo 'FAIL: Invalid IPA was accepted.' >&2
  exit 1
fi
[[ ! -e "$QA_DIRECTORY/output.ipa" ]] || { echo 'FAIL: Invalid input produced an export.' >&2; exit 1; }
if "$BIN_DIR/loadside" sign --unknown >/dev/null 2>&1; then
  echo 'FAIL: Unknown arguments were accepted.' >&2
  exit 1
fi
if "$BIN_DIR/loadside" sign --ipa >/dev/null 2>&1; then
  echo 'FAIL: Missing arguments were accepted.' >&2
  exit 1
fi
if [[ -n "$(git ls-files '*.p12' '*.pfx' '*.mobileprovision' '*.provisionprofile' '*.keychain*' '*.ipa' '*.pem' '*.key')" ]]; then
  echo 'FAIL: Signing material or an IPA appears in the source tree.' >&2
  exit 1
fi
echo 'Checks passed.'
