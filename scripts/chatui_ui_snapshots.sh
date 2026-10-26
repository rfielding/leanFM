#!/usr/bin/env bash
set -euo pipefail
# Refs: named_ui_scenarios_are_keyboard_and_braille_first; No visual-only UI evidence.
installation_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python_bin="$(command -v python3)"
lean_bin="$(elan which lean)"
mkdir -p "$installation_root/book/assets/ui-tour" "$installation_root/reports/ui-tour"
args=(bwrap --die-with-parent --new-session --unshare-all --uid 1000 --gid 1000 --cap-drop ALL
  --ro-bind / / --proc /proc --dev /dev
  --tmpfs /tmp --chmod 1777 /tmp
  --tmpfs "$installation_root/.cache" --chmod 0777 "$installation_root/.cache"
  --tmpfs "$installation_root/.leanfm" --chmod 0777 "$installation_root/.leanfm"
  --tmpfs "$installation_root/projects" --dir "$installation_root/projects/GoServer")
# Read only the selected fixture's durable inputs. Real conversations and runtime
# records, all other projects, and the installation account vault are absent.
for relative in source spec book manifest.json reports/specification-check .leanfm/acceptance.json .leanfm/accepted; do
  args+=(--ro-bind "$installation_root/projects/GoServer/$relative" "$installation_root/projects/GoServer/$relative")
done
for private in .ssh .aws .codex .gnupg .config; do
  if [[ -d "$HOME/$private" ]]; then args+=(--tmpfs "$HOME/$private"); fi
done
args+=(--bind "$installation_root/book/assets/ui-tour" "$installation_root/book/assets/ui-tour"
  --bind "$installation_root/reports/ui-tour" "$installation_root/reports/ui-tour"
  --bind "$installation_root/reports/application-launch-review" "$installation_root/reports/application-launch-review"
  --chdir "$installation_root" --clearenv
  --setenv HOME /tmp --setenv LANG C.UTF-8 --setenv LC_ALL C.UTF-8
  --setenv PATH "$(dirname "$python_bin"):$(dirname "$lean_bin"):/usr/bin:/bin"
  --setenv XDG_CACHE_HOME "$installation_root/.cache/font-cache"
  -- "$python_bin" scripts/chatui_application_test.py --screenshots)
"${args[@]}" >"$installation_root/reports/ui-tour/capture.log" 2>&1
cat "$installation_root/reports/ui-tour/capture.log"
