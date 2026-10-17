#!/usr/bin/env bash
set -euo pipefail

# Manual irreversible cleanup for transient/log files in this LeanFM project.
# USAGE:
#   From repository root or anywhere: bash data/accounts/rob/projects/c931835956ab201b/tools/cleanup_transient.sh
#   To skip confirmation: bash .../cleanup_transient.sh --yes
#
# WARNING: This script permanently deletes files. There is no undo.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Patterns (relative to project root) of files to delete
PATTERNS=(
  "spec/images/*_log.txt"
  "spec/images/generation_*.txt"
  "conversations/*.log"
  "logs/*.log"
)

# Collect matching files using safe bash globbing
shopt -s nullglob
files=()
for p in "${PATTERNS[@]}"; do
  for f in "$PROJECT_ROOT"/$p; do
    if [ -f "$f" ]; then
      files+=("$f")
    fi
  done
done
shopt -u nullglob

if [ ${#files[@]} -eq 0 ]; then
  echo "No transient files found for deletion in project: $PROJECT_ROOT"
  exit 0
fi

echo "The following files will be PERMANENTLY DELETED (irreversible):"
for f in "${files[@]}"; do
  echo "  $f"
done

# Confirmation unless --yes or -y supplied
if [ "${1:-}" != "--yes" ] && [ "${1:-}" != "-y" ]; then
  echo
  read -r -p "Proceed and delete these files? Type 'yes' to confirm: " ans
  if [ "$ans" != "yes" ]; then
    echo "Aborted. No files were deleted."
    exit 2
  fi
fi

# Perform deletion
printf "\nDeleting...\n"
for f in "${files[@]}"; do
  rm -f -- "$f" && printf "deleted: %s\n" "$f"
done

echo "Done. Deleted ${#files[@]} files."
exit 0
