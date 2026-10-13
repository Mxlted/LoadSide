#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -eq 1 && "$1" == '--help' ]]; then
  echo 'Usage: scripts/check.sh [--skip-build]'
  echo 'Run formatting, tests, a release build, CLI smoke checks and repository hygiene checks.'
  echo '--skip-build skips tests and compilation; existing release binaries are required.'
  exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--skip-build" ) ]]; then
  echo 'Usage: scripts/check.sh [--skip-build]' >&2
  exit 2
fi
for script in scripts/*.sh; do bash -n "$script"; done
scripts/format.sh --check
scripts/check-packaging.sh
source scripts/build-support.sh
loadside_configure_build
if [[ $# -eq 0 ]]; then
  swift test "${LOADSIDE_SWIFT_BUILD_FLAGS[@]}" -Xswiftc -warnings-as-errors -Xcc -Werror=deprecated-declarations
  swift build -c release "${LOADSIDE_SWIFT_BUILD_FLAGS[@]}" -Xswiftc -warnings-as-errors -Xcc -Werror=deprecated-declarations
fi
BIN_DIR="$(swift build -c release "${LOADSIDE_SWIFT_BUILD_FLAGS[@]}" --show-bin-path)"
loadside_verify_binary_sdk "$BIN_DIR/LoadSideApp"
loadside_verify_binary_sdk "$BIN_DIR/loadside"
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
if "$BIN_DIR/loadside" inject --ipa "$QA_DIRECTORY/invalid.ipa" --inject "$QA_DIRECTORY/invalid.ipa" --output "$QA_DIRECTORY/unsigned.ipa" >"$QA_DIRECTORY/inject.log" 2>&1; then
  echo 'FAIL: Invalid injection archive was accepted.' >&2
  exit 1
fi
[[ ! -e "$QA_DIRECTORY/unsigned.ipa" ]] || { echo 'FAIL: Invalid injection produced an export.' >&2; exit 1; }
if "$BIN_DIR/loadside" inject --ipa "$QA_DIRECTORY/invalid.ipa" --inject "$QA_DIRECTORY/invalid.ipa" --output "$QA_DIRECTORY/unsigned.ipa" --password-stdin >"$QA_DIRECTORY/inject-options.log" 2>&1; then
  echo 'FAIL: Inject accepted a signing credential option.' >&2
  exit 1
fi
[[ "$(cat "$QA_DIRECTORY/inject-options.log")" == *'[arguments.inject]'* ]] || { echo 'FAIL: Inject did not reject signing options before reading credentials.' >&2; exit 1; }
if "$BIN_DIR/loadside" sign --unknown >/dev/null 2>&1; then
  echo 'FAIL: Unknown arguments were accepted.' >&2
  exit 1
fi
if "$BIN_DIR/loadside" sign --ipa >/dev/null 2>&1; then
  echo 'FAIL: Missing arguments were accepted.' >&2
  exit 1
fi
for conflicting_policy in --require-matching-extension-profiles --remove-extensions; do
  if "$BIN_DIR/loadside" sign --reuse-main-profile-for-extensions "$conflicting_policy" >"$QA_DIRECTORY/extension-policy.log" 2>&1; then
    echo 'FAIL: Conflicting extension signing policies were accepted.' >&2
    exit 1
  fi
  [[ "$(cat "$QA_DIRECTORY/extension-policy.log")" == *'[arguments.extensionPolicy]'* ]] || { echo 'FAIL: Conflicting extension policies did not produce the expected diagnostic.' >&2; exit 1; }
done
if [[ -n "$(git ls-files '*.p12' '*.pfx' '*.mobileprovision' '*.provisionprofile' '*.keychain*' '*.ipa' '*.pem' '*.key')" ]]; then
  echo 'FAIL: Signing material or an IPA appears in the source tree.' >&2
  exit 1
fi
echo 'Checks passed.'
