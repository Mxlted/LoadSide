#!/bin/bash
# Use the formatter shipped with the selected Swift toolchain; no package install.
set -euo pipefail
cd "$(dirname "$0")/.."
usage() {
  echo 'Usage: scripts/format.sh [--check]'
  echo 'Format owned Swift sources, or fail if formatting differs with --check.'
}
if [[ $# -eq 1 && "$1" == '--help' ]]; then usage; exit 0; fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != '--check' ) ]]; then usage >&2; exit 2; fi
if ! swift format --help >/dev/null 2>&1; then
  echo 'Select a Swift 6+ toolchain that includes swift format.' >&2
  exit 1
fi
if [[ $# -eq 1 ]]; then
  swift format lint --strict --configuration .swift-format --recursive Package.swift Sources Tests scripts/make-icon.swift
else
  swift format format --in-place --configuration .swift-format --recursive Package.swift Sources Tests scripts/make-icon.swift
fi
