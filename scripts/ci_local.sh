#!/usr/bin/env bash
# Reproduce GitHub CI (.github/workflows/lean_action_ci.yml) on a fresh copy of this working
# tree, so a check that passes only because of stale build output here fails here first.
#
# The copy is every tracked file and every untracked file git does not ignore, as they are now
# (uncommitted edits included), in .cache/ci-local/tree with no .lake build output. It then runs
# what CI runs after checkout, in CI's order, and reports every step's result rather than stopping
# at the first failure.
#
#   bash scripts/ci_local.sh          # the Lean checks: build, validate, self-hosting, generated outputs
#   bash scripts/ci_local.sh --all    # also the ChatUI checks (needs bubblewrap, npm and the Go toolchain)
#
# A fresh build of the whole library takes a while; that is the point.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work="$root/.cache/ci-local/tree"
all=0
[ "${1:-}" = "--all" ] && all=1

rm -rf "$work"
mkdir -p "$work"
( cd "$root" && git ls-files -co --exclude-standard -z | tar --null -T - -cf - ) | tar -xf - -C "$work"
cd "$work"
git -C "$work" init -q && git -C "$work" add -A >/dev/null 2>&1 && \
  git -C "$work" -c user.name=ci-local -c user.email=ci-local@localhost commit -qm "working tree" >/dev/null

failed=()
step() {
  local name="$1"; shift
  echo "=== $name"
  if "$@"; then echo "--- ok: $name"; else echo "--- FAILED: $name"; failed+=("$name"); fi
}

# leanprover/lean-action: lake build of the default targets
step "lake build (lean-action)" lake build
step "copy the dark PDF over the light one (as CI does)" cp book/main-dark.pdf book/main.pdf
if [ $all -eq 1 ]; then
  step "make go-toolchain" make go-toolchain
  step "make chatui-check" make chatui-check
fi
step "make validate" make validate
step "make selfhost-check" make selfhost-check
step "generated protocol outputs are current" bash -c \
  'lake env lean --run NeedhamSchroeder.lean && git diff --exit-code -- book/generated SELF_HOSTING_REVIEW.md'

echo
if [ ${#failed[@]} -eq 0 ]; then
  echo "ci-local: every step passed"
else
  printf 'ci-local: FAILED: %s\n' "${failed[@]}"
  exit 1
fi
