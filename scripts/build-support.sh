#!/bin/bash
# Shared compiler/linker settings for macOS verification and packaging scripts.
# Swift's Darwin link driver can pass --sysroot where clang needs -isysroot,
# causing LC_BUILD_VERSION.sdk to equal the deployment target instead of the SDK.
# See https://github.com/swiftlang/swift-package-manager/issues/8886.

loadside_configure_build() {
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
    --sdk "$LOADSIDE_MACOS_SDK_PATH"
    -Xswiftc -Xclang-linker -Xswiftc -isysroot
    -Xswiftc -Xclang-linker -Xswiftc "$LOADSIDE_MACOS_SDK_PATH"
  )
}

loadside_normalize_version() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
  /usr/bin/awk -F. '{ printf "%d.%d.%d", $1, $2, $3 }' <<< "$1"
}

loadside_verify_binary_sdk() {
  local binary="$1" architectures architecture metadata platform minimum sdk
  local expected_minimum expected_sdk
  expected_minimum="$(loadside_normalize_version "$LOADSIDE_MINIMUM_MACOS")" || return
  expected_sdk="$(loadside_normalize_version "$LOADSIDE_MACOS_SDK_VERSION")" || return
  if ! architectures="$(/usr/bin/lipo -archs "$binary" 2>/dev/null)" || [[ -z "$architectures" ]]; then
    echo "Cannot inspect build metadata for $binary. Rebuild with scripts/package.sh --local (without --skip-build)." >&2
    return 1
  fi
  for architecture in $architectures; do
    metadata="$(/usr/bin/vtool -arch "$architecture" -show-build "$binary" 2>/dev/null)" || {
      echo "Cannot read $architecture SDK metadata in $binary. Rebuild with scripts/package.sh --local (without --skip-build)." >&2
      return 1
    }
    platform="$(/usr/bin/awk '$1 == "platform" { print $2 }' <<< "$metadata")"
    minimum="$(/usr/bin/awk '$1 == "minos" { print $2 }' <<< "$metadata")"
    sdk="$(/usr/bin/awk '$1 == "sdk" { print $2 }' <<< "$metadata")"
    if [[ "$platform" != MACOS ]] || [[ "$(loadside_normalize_version "$minimum")" != "$expected_minimum" || "$(loadside_normalize_version "$sdk")" != "$expected_sdk" ]]; then
      echo "Incorrect $architecture build metadata in $binary: minimum macOS ${minimum:-unknown}, SDK ${sdk:-unknown}; expected minimum $LOADSIDE_MINIMUM_MACOS, SDK $LOADSIDE_MACOS_SDK_VERSION." >&2
      echo 'Rebuild with scripts/package.sh --local (without --skip-build), or scripts/check.sh, using the selected Xcode SDK.' >&2
      return 1
    fi
  done
}
