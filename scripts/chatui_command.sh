#!/usr/bin/env bash
set -euo pipefail

# The sole third-party command boundary for the ChatUI workspace agent.
# Each operation below has fixed executable semantics; arbitrary shell text is
# deliberately not accepted.
operation="${1:-}"
shift || true

unset LD_LIBRARY_PATH LD_PRELOAD

case "$operation" in
  list-files)
    test "$#" -eq 1
    exec rg --files -- "$1"
    ;;
  search-literal)
    test "$#" -eq 2
    exec rg -n -F -- "$1" "$2"
    ;;
  git-apply-check|git-apply)
    test "$#" -eq 1
    installation_root="$(dirname "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")")"
    exec python3 "$installation_root/scripts/chatui_patch.py" "$operation" "$1"
    ;;
  check-build|check-check|check-book)
    test "$#" -eq 1
    target="${operation#check-}"
    exec timeout 300 make -C "$1" "$target"
    ;;
  check-http)
    test "$#" -eq 1
    exec timeout 300 make -C "$1" http-check
    ;;
  build-book)
    test "$#" -eq 1
    book_root="$1"
    installation_root="$(dirname "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")")"
    if [[ "${LEANFM_TEST_UNSANDBOXED_BOOK_BUILD:-}" == "1" &&
        ( "$book_root" == /tmp/leanfm-chatui-check.* || "$book_root" == "$installation_root"/.cache/chatui-check.* ) ]]; then
      timeout 300 make -C "$book_root" 2>&1 | iconv -c -f UTF-8 -t UTF-8
    else
      timeout 300 bwrap --die-with-parent --unshare-pid --unshare-ipc --unshare-uts \
        --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
        --ro-bind /etc /etc --ro-bind /var/lib/texmf /var/lib/texmf --proc /proc --dev /dev \
        --tmpfs /tmp --bind "$book_root" /work --chdir /work --setenv HOME /tmp -- \
        /usr/bin/make 2>&1 | iconv -c -f UTF-8 -t UTF-8
    fi
    ;;
  check-go)
    test "$#" -eq 1
    go_root="$1"
    if [[ -f "$1/source/go.mod" ]]; then
      go_root="$1/source"
    fi
    exec timeout 300 go -C "$go_root" test ./...
    ;;
  generate-gif)
    test "$#" -eq 3
    root="$1"
    script_relative="$2"
    output_relative="$3"
    exec timeout 60 bwrap --die-with-parent --new-session \
      --unshare-pid --unshare-ipc --unshare-uts \
      --ro-bind /usr /usr --ro-bind /usr/local /usr/local \
      --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
      --proc /proc --dev /dev --tmpfs /tmp \
      --bind "$root" /work --chdir /work \
      /usr/bin/python3 "/work/$script_relative" "/work/$output_relative"
    ;;
  transcode-mp4)
    test "$#" -eq 2
    exec timeout 120 /usr/bin/ffmpeg -hide_banner -loglevel error -y \
      -i "$1" -vf 'scale=trunc(iw/2)*2:trunc(ih/2)*2' \
      -an -c:v libx264 -preset medium -crf 20 -profile:v high \
      -pix_fmt yuv420p -movflags +faststart "$2"
    ;;
  *)
    printf 'Unsupported ChatUI command operation: %s\n' "$operation" >&2
    exit 64
    ;;
esac
