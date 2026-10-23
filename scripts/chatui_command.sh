#!/usr/bin/env bash
set -euo pipefail

# The sole third-party command boundary for the ChatUI workspace agent.
# Each operation below has fixed executable semantics; arbitrary shell text is
# deliberately not accepted.
operation="${1:-}"
shift || true

unset LD_LIBRARY_PATH LD_PRELOAD

case "$operation" in
  project-status|project-accept|project-authorize)
    installation_root="$(dirname "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")")"
    exec timeout 15 python3 "$installation_root/scripts/chatui_project_state.py" "${operation#project-}" "$@"
    ;;
  workspace-list|workspace-resolve)
    installation_root="$(dirname "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")")"
    exec timeout 10 python3 "$installation_root/scripts/chatui_workspace.py" "${operation#workspace-}" "$@"
    ;;
  media-upload|media-resolve)
    test "$#" -eq 1
    installation_root="$(dirname "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")")"
    exec timeout 20 python3 "$installation_root/scripts/chatui_media.py" "${operation#media-}" "$1"
    ;;
  list-files)
    test "$#" -eq 1
    exec rg --files -- "$1"
    ;;
  search-literal)
    test "$#" -eq 2
    exec rg -n -F -- "$1" "$2"
    ;;
  check-specification)
    test "$#" -eq 4
    installation_root="$(dirname "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")")"
    exec timeout 240 python3 "$installation_root/scripts/chatui_specification.py" "$@"
    ;;
  git-apply-check|git-apply)
    test "$#" -eq 1
    installation_root="$(dirname "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")")"
    exec python3 "$installation_root/scripts/chatui_patch.py" "$operation" "$1"
    ;;
  check-build|check-check|check-book|check-http|check-go)
    test "$#" -eq 1
    target="${operation#check-}"
    if [[ "$target" == http ]]; then target=http-check; fi
    installation_root="$(dirname "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")")"
    exec timeout 310 python3 "$installation_root/scripts/chatui_command_runner.py" "$target" "$1"
    ;;
  build-book)
    test "$#" -eq 1
    book_root="$1"
    installation_root="$(dirname "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")")"
    if [[ "${LEANFM_TEST_UNSANDBOXED_BOOK_BUILD:-}" == "1" &&
        ( "$book_root" == /tmp/leanfm-chatui-check.* || "$book_root" == "$installation_root"/.cache/chatui-check.* ) ]]; then
      timeout 300 make -C "$book_root" 2>&1 | iconv -c -f UTF-8 -t UTF-8
    else
      project_root="$(dirname "$book_root")"
      if [[ -d "$project_root/spec" ]]; then
        timeout 310 python3 "$installation_root/scripts/chatui_command_runner.py" book "$project_root" 2>&1 | iconv -c -f UTF-8 -t UTF-8
        exit "${PIPESTATUS[0]}"
      fi
      timeout 300 bwrap --die-with-parent --unshare-pid --unshare-ipc --unshare-uts --unshare-net \
        --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
        --ro-bind /etc /etc --ro-bind /var/lib/texmf /var/lib/texmf --proc /proc --dev /dev \
        --tmpfs /tmp --bind "$book_root" /work --chdir /work --clearenv --setenv PATH /usr/bin:/bin --setenv HOME /tmp -- \
        /usr/bin/make 2>&1 | iconv -c -f UTF-8 -t UTF-8
    fi
    ;;
  generate-gif)
    test "$#" -eq 3
    installation_root="$(dirname "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")")"
    exec timeout 70 python3 "$installation_root/scripts/chatui_gif.py" "$@"
    ;;
  transcode-mp4)
    test "$#" -eq 3
    installation_root="$(dirname "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")")"
    exec timeout 130 python3 "$installation_root/scripts/chatui_mp4.py" "$@"
    ;;
  *)
    printf 'Unsupported ChatUI command operation: %s\n' "$operation" >&2
    exit 64
    ;;
esac
