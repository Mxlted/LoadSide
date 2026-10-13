#!/bin/bash
# Shared compiler/linker settings for macOS verification and packaging scripts.
# Swift's Darwin link driver can pass --sysroot where clang needs -isysroot,
# causing LC_BUILD_VERSION.sdk to equal the deployment target instead of the SDK.
# See https://github.com/swiftlang/swift-package-manager/issues/8886.

loadside_validate_host() {
  if [[ "$1" != Darwin || "$2" != arm64 ]]; then
    echo 'LoadSide requires Apple Silicon and a native arm64 macOS toolchain. Intel Macs and Rosetta build sessions are unsupported.' >&2
    return 1
  fi
}

loadside_require_supported_host() {
  loadside_validate_host "$(/usr/bin/uname -s)" "$(/usr/bin/uname -m)"
}

loadside_validate_git_history() {
  # CFBundleVersion comes from the commit count, so a shallow checkout would
  # produce a different (usually 1) build number for the same source commit.
  [[ "$1" == false ]] || {
    echo 'Packaging requires complete Git history. Fetch with git fetch --unshallow, or use checkout fetch-depth: 0 in CI.' >&2
    return 1
  }
}

loadside_validate_release_version() {
  local component
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] || return 1
  if [[ "$1" == *-* ]]; then
    local suffix="${1#*-}"
    local components
    IFS=. read -r -a components <<< "$suffix"
    for component in "${components[@]}"; do
      [[ ! "$component" =~ ^0[0-9]+$ ]] || return 1
    done
  fi
}

loadside_publish_file() {
  # os.link creates exactly this destination or fails; unlike ln(1), it cannot
  # follow a destination directory that appears between checking and publishing.
  python3 - "$1" "$2" <<'PY'
import os
import sys

try:
    os.link(sys.argv[1], sys.argv[2])
except OSError as error:
    sys.exit(f"Cannot publish artifact without overwriting: {error.strerror}")
PY
}

loadside_configure_build() {
  loadside_require_supported_host || return
  LOADSIDE_MACOS_SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)" || return
  LOADSIDE_MACOS_SDK_VERSION="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)" || return
  LOADSIDE_MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Assets/Info.plist)" || return
  if [[ ! -d "$LOADSIDE_MACOS_SDK_PATH" || ! "$LOADSIDE_MACOS_SDK_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ || ! "$LOADSIDE_MINIMUM_MACOS" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo 'Cannot determine the selected macOS SDK and minimum supported macOS version.' >&2
    return 1
  fi
  # Give the same SDK to compilation and to clang's link driver. The deployment
  # target still comes from Package.swift; no SDK version is invented or patched.
  LOADSIDE_SWIFT_BUILD_FLAGS=(
    --arch arm64
    --sdk "$LOADSIDE_MACOS_SDK_PATH"
    -Xswiftc -Xclang-linker -Xswiftc -isysroot
    -Xswiftc -Xclang-linker -Xswiftc "$LOADSIDE_MACOS_SDK_PATH"
    -Xswiftc -warnings-as-errors
    -Xcc -Werror=deprecated-declarations
  )
}

loadside_normalize_version() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
  /usr/bin/awk -F. '{ printf "%d.%d.%d", $1, $2, $3 }' <<< "$1"
}

loadside_verify_binary_sdk() {
  local binary="$1" architectures metadata platform minimum sdk
  local expected_minimum expected_sdk
  expected_minimum="$(loadside_normalize_version "$LOADSIDE_MINIMUM_MACOS")" || return
  expected_sdk="$(loadside_normalize_version "$LOADSIDE_MACOS_SDK_VERSION")" || return
  if ! architectures="$(/usr/bin/lipo -archs "$binary" 2>/dev/null)" || [[ -z "$architectures" ]]; then
    echo "Cannot inspect build metadata for $binary. Rebuild with scripts/package.sh --local (without --skip-build)." >&2
    return 1
  fi
  if [[ "$architectures" != arm64 ]]; then
    echo "Only native arm64 binaries may ship with LoadSide; found '$architectures' in $binary." >&2
    return 1
  fi
  metadata="$(/usr/bin/vtool -arch arm64 -show-build "$binary" 2>/dev/null)" || {
    echo "Cannot read arm64 SDK metadata in $binary. Rebuild with scripts/package.sh --local (without --skip-build)." >&2
    return 1
  }
  platform="$(/usr/bin/awk '$1 == "platform" { print $2 }' <<< "$metadata")"
  minimum="$(/usr/bin/awk '$1 == "minos" { print $2 }' <<< "$metadata")"
  sdk="$(/usr/bin/awk '$1 == "sdk" { print $2 }' <<< "$metadata")"
  if [[ "$platform" != MACOS ]] || [[ "$(loadside_normalize_version "$minimum")" != "$expected_minimum" || "$(loadside_normalize_version "$sdk")" != "$expected_sdk" ]]; then
    echo "Incorrect arm64 build metadata in $binary: minimum macOS ${minimum:-unknown}, SDK ${sdk:-unknown}; expected minimum $LOADSIDE_MINIMUM_MACOS, SDK $LOADSIDE_MACOS_SDK_VERSION." >&2
    echo 'Rebuild with scripts/package.sh --local (without --skip-build), or scripts/check.sh, using the selected Xcode SDK.' >&2
    return 1
  fi
}

loadside_verify_bundle_binaries() (
  set -o pipefail
  local binary description
  [[ -d "$1" ]] || { echo "Cannot inspect bundle binaries: $1 is not a directory." >&2; return 1; }
  # Inspect helpers and any future embedded Mach-O libraries as well as the app.
  /usr/bin/find "$1" -type f -print0 | while IFS= read -r -d '' binary; do
    description="$(/usr/bin/file -b "$binary")" || return
    if [[ -x "$binary" || "$description" == *Mach-O* ]]; then
      loadside_verify_binary_sdk "$binary" || return
    fi
  done
)
