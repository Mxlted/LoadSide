#!/bin/bash
# Remove only generated repository output. Imported signing inputs stay intact.
set -euo pipefail
cd "$(dirname "$0")/.."
usage() {
  cat <<'EOF'
Usage: scripts/clean.sh [--include-dist] [--dry-run]

Remove .build/ and build/ (compiler caches, development apps and QA scratch work).
Keep the current dist/LoadSide.app and CLI by default.
--include-dist also removes dist/, including any explicitly created release ZIPs.
--dry-run prints the generated directories that would be removed.
Files outside these generated directories, including test_materials/, stay untouched.
EOF
}
INCLUDE_DIST=false
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage; exit 0 ;;
    --include-dist) INCLUDE_DIST=true ;;
    --dry-run) DRY_RUN=true ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
TARGETS=("$PWD/.build" "$PWD/build")
if [[ "$INCLUDE_DIST" == true ]]; then TARGETS+=("$PWD/dist"); fi
for target in "${TARGETS[@]}"; do
  if [[ -e "$target" || -L "$target" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      echo "Would remove $target"
    else
      rm -rf -- "$target"
      echo "Removed $target"
    fi
  fi
done
