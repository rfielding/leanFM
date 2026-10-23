#!/usr/bin/env bash
# requirement:selfhost.mcp.context, requirement:selfhost.mcp.readonly
# AGENTS.md: keep project-owned session state beneath the project root.
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

if ! command -v claude >/dev/null 2>&1; then
  echo "Claude Code is not installed. See https://code.claude.com/docs/en/setup" >&2
  exit 127
fi

# Resolve before creating anything, including when .cache already is a symlink.
state_root="$(realpath -m -- "$project_root/.cache/claude")"
temp_root="$(realpath -m -- "$state_root/tmp")"
for directory in "$state_root" "$temp_root"; do
  case "$directory" in
    "$project_root"/*) ;;
    *) echo "Claude state must stay beneath the LeanFM project root." >&2; exit 1 ;;
  esac
done

umask 077
mkdir -p -- "$state_root" "$temp_root"
export CLAUDE_CONFIG_DIR="$state_root"
export CLAUDE_CODE_TMPDIR="$temp_root"
export TMPDIR="$temp_root"
cd -- "$project_root"
exec claude "$@"
