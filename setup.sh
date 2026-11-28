#!/usr/bin/env bash
# LeanFM's setup (clause selfhost.setup), generated from LeanFM/Deps.lean by SetupScript.lean: do not edit.
# Usage: ./setup.sh [build|book|check|videos|tla|all] [--check] [--quiet] [--list]
#   installs what the target needs and is missing (build unless named; book and check include build);
#   --check only reports what is missing, and exits 1 when something is; --quiet says nothing when
#   nothing is; --list prints what the target needs, each with its test and how to install it.
set -o pipefail
cd "$(dirname "$0")"
target=build; mode=install; quiet=
for a in "$@"; do
  case "$a" in
    --check) mode=check ;;
    --quiet) quiet=1 ;;
    --list) mode=list ;;
    build|book|check|videos|tla|all) target=$a ;;
    *) echo "usage: ./setup.sh [build|book|check|videos|tla|all] [--check] [--quiet] [--list]"; exit 2 ;;
  esac
done
case "$target" in
  build) want=" build " ;; book) want=" build book " ;; check) want=" build book check " ;;
  videos) want=" build videos " ;; tla) want=" build tla " ;; *) want=" build book check videos tla " ;;
esac
if [ "$(uname)" = Darwin ]; then os=mac; elif command -v apt-get >/dev/null 2>&1; then os=apt; else os=other; fi
export PATH="$HOME/.elan/bin:$PATH"
needed() { for t in $1; do case "$want" in *" $t "*) return 0 ;; esac; done; return 1; }
present() { ( eval "$1" ) >/dev/null 2>&1; }
missing=(); apt=(); brew=(); cask=(); runs=()
if [ "$mode" = list ] && needed 'build'; then
  printf '%s\n' '- git: the repository' '  test: command -v git' '  apt: sudo apt-get install -y git' '  brew: brew install git'
fi
if [ "$mode" = list ] && needed 'build'; then
  printf '%s\n' '- make: the make targets' '  test: command -v make' '  apt: sudo apt-get install -y make' '  brew: brew install make'
fi
if [ "$mode" = list ] && needed 'build'; then
  printf '%s\n' '- flock: one make at a time in a checkout' '  test: command -v flock' '  apt: sudo apt-get install -y util-linux' '  brew: brew install flock'
fi
if [ "$mode" = list ] && needed 'build'; then
  printf '%s\n' '- curl: downloads (elan, Go)' '  test: command -v curl' '  apt: sudo apt-get install -y curl ca-certificates' '  brew: brew install curl'
fi
if [ "$mode" = list ] && needed 'build'; then
  printf '%s\n' '- Python 3 with pip: the scripts and checks' '  test: command -v python3 && python3 -m pip --version' '  apt: sudo apt-get install -y python3 python3-pip' '  brew: brew install python'
fi
if [ "$mode" = list ] && needed 'build'; then
  printf '%s\n' '- Node.js 18 or later and npm: the viewer'\''s bundle (ui/)' '  test: node -e '\''process.exit(+process.versions.node.split(".")[0] >= 18 ? 0 : 1)'\'' && command -v npm' '  apt: sudo apt-get install -y nodejs npm' '  brew: brew install node'
fi
if [ "$mode" = list ] && needed 'build'; then
  printf '%s\n' '- elan (Lean and Lake): builds LeanFM; installs the Lean in lean-toolchain by itself' '  test: command -v lake || test -x "$HOME/.elan/bin/lake"' '  run: curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none'
fi
if [ "$mode" = list ] && needed 'book'; then
  printf '%s\n' '- TeX Live: the book'\''s PDFs' '  test: command -v pdflatex && command -v bibtex && command -v makeindex && kpsewhich pgfplots.sty tgheros.sty' '  apt: sudo apt-get install -y texlive-latex-extra texlive-pictures texlive-science texlive-fonts-recommended texlive-fonts-extra texlive-bibtex-extra' '  brew: brew install --cask mactex-no-gui'
fi
if [ "$mode" = list ] && needed 'book'; then
  printf '%s\n' '- Graphviz: the book'\''s graphs' '  test: command -v dot' '  apt: sudo apt-get install -y graphviz' '  brew: brew install graphviz'
fi
if [ "$mode" = list ] && needed 'book'; then
  printf '%s\n' '- Poppler utilities: the book'\''s pages in the viewer and the PDF checks' '  test: command -v pdftoppm && command -v pdftotext && command -v pdfinfo' '  apt: sudo apt-get install -y poppler-utils' '  brew: brew install poppler'
fi
if [ "$mode" = list ] && needed 'book'; then
  printf '%s\n' '- Playwright with Chromium: SVG to PDF for the book, and the viewer checks' '  test: python3 -c '\''import playwright'\'' && test -n "$(ls -d "$HOME"/.cache/ms-playwright/chromium-* "$HOME"/Library/Caches/ms-playwright/chromium-* 2>/dev/null)"' '  run: python3 -m pip install --user playwright 2>/dev/null || python3 -m pip install --user --break-system-packages playwright; python3 -m playwright install --with-deps chromium'
fi
if [ "$mode" = list ] && needed 'check'; then
  printf '%s\n' '- Pillow and CairoSVG: the chat UI'\''s image checks' '  test: python3 -c '\''import PIL, cairosvg'\''' '  apt: sudo apt-get install -y python3-pil python3-cairosvg' '  run: python3 -c '\''import PIL, cairosvg'\'' 2>/dev/null || python3 -m pip install --user pillow cairosvg 2>/dev/null || python3 -m pip install --user --break-system-packages pillow cairosvg'
fi
if [ "$mode" = list ] && needed 'check'; then
  printf '%s\n' '- bubblewrap: the sandbox the checks run generated code in' '  test: command -v bwrap' '  apt: sudo apt-get install -y bubblewrap'
fi
if [ "$mode" = list ] && needed 'check'; then
  printf '%s\n' '- ripgrep: the checks'\'' searches' '  test: command -v rg' '  apt: sudo apt-get install -y ripgrep' '  brew: brew install ripgrep'
fi
if [ "$mode" = list ] && needed 'check'; then
  printf '%s\n' '- ss: finding a running server'\''s port' '  test: command -v ss' '  apt: sudo apt-get install -y iproute2'
fi
if [ "$mode" = list ] && needed 'check videos'; then
  printf '%s\n' '- Google Chrome: the headless viewer in make run-log-check and the videos' '  test: test -x /usr/bin/google-chrome' '  run: if command -v apt-get >/dev/null; then curl -fsSLo /tmp/leanfm-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && sudo apt-get install -y /tmp/leanfm-chrome.deb && rm -f /tmp/leanfm-chrome.deb; else echo '\''install Google Chrome at /usr/bin/google-chrome'\''; fi'
fi
if [ "$mode" = list ] && needed 'check'; then
  printf '%s\n' '- Go (checksum-pinned, in .toolchains/): the Go example'\''s checks' '  test: test -x .toolchains/go/bin/go' '  run: make go-toolchain'
fi
if [ "$mode" = list ] && needed 'videos'; then
  printf '%s\n' '- FFmpeg: the videos' '  test: command -v ffmpeg' '  apt: sudo apt-get install -y ffmpeg' '  brew: brew install ffmpeg'
fi
if [ "$mode" = list ] && needed 'videos'; then
  printf '%s\n' '- the video environment (video/.conda: Python with Manim and Piper): rendering and narrating the videos' '  test: video/.conda/bin/python -c '\''import manim, piper'\''' '  apt: sudo apt-get install -y libcairo2-dev libpango1.0-dev pkg-config' '  brew: brew install cairo pango pkg-config' '  run: if command -v conda >/dev/null; then conda create -y -p video/.conda python=3.11 pip && video/.conda/bin/python -m pip install manim piper-tts; else echo '\''install conda (Miniforge: https://conda-forge.org/download), then run ./setup.sh videos again'\''; fi'
fi
if [ "$mode" = list ] && needed 'tla'; then
  printf '%s\n' '- Java: TLC, for the TLA+ comparison (make tla-check)' '  test: command -v java' '  apt: sudo apt-get install -y default-jre-headless' '  brew: brew install openjdk'
fi
if [ "$mode" = list ] && needed 'tla'; then
  printf '%s\n' '- TLA+ tools (checksum-pinned, in .toolchains/): the TLA+ comparison' '  test: test -f .toolchains/tla/tla2tools-1.7.4.jar' '  run: make tla-toolchain'
fi
if [ "$mode" = list ]; then exit 0; fi
if needed 'build' && ! present 'command -v git'; then
  missing+=('git'); apt+=(git); brew+=(git); cask+=()
fi
if needed 'build' && ! present 'command -v make'; then
  missing+=('make'); apt+=(make); brew+=(make); cask+=()
fi
if needed 'build' && ! present 'command -v flock'; then
  missing+=('flock'); apt+=(util-linux); brew+=(flock); cask+=()
fi
if needed 'build' && ! present 'command -v curl'; then
  missing+=('curl'); apt+=(curl ca-certificates); brew+=(curl); cask+=()
fi
if needed 'build' && ! present 'command -v python3 && python3 -m pip --version'; then
  missing+=('Python 3 with pip'); apt+=(python3 python3-pip); brew+=(python); cask+=()
fi
if needed 'build' && ! present 'node -e '\''process.exit(+process.versions.node.split(".")[0] >= 18 ? 0 : 1)'\'' && command -v npm'; then
  missing+=('Node.js 18 or later and npm'); apt+=(nodejs npm); brew+=(node); cask+=()
fi
if needed 'build' && ! present 'command -v lake || test -x "$HOME/.elan/bin/lake"'; then
  missing+=('elan (Lean and Lake)'); apt+=(); brew+=(); cask+=()
  runs+=(elan)
fi
if needed 'book' && ! present 'command -v pdflatex && command -v bibtex && command -v makeindex && kpsewhich pgfplots.sty tgheros.sty'; then
  missing+=('TeX Live'); apt+=(texlive-latex-extra texlive-pictures texlive-science texlive-fonts-recommended texlive-fonts-extra texlive-bibtex-extra); brew+=(); cask+=(mactex-no-gui)
fi
if needed 'book' && ! present 'command -v dot'; then
  missing+=('Graphviz'); apt+=(graphviz); brew+=(graphviz); cask+=()
fi
if needed 'book' && ! present 'command -v pdftoppm && command -v pdftotext && command -v pdfinfo'; then
  missing+=('Poppler utilities'); apt+=(poppler-utils); brew+=(poppler); cask+=()
fi
if needed 'book' && ! present 'python3 -c '\''import playwright'\'' && test -n "$(ls -d "$HOME"/.cache/ms-playwright/chromium-* "$HOME"/Library/Caches/ms-playwright/chromium-* 2>/dev/null)"'; then
  missing+=('Playwright with Chromium'); apt+=(); brew+=(); cask+=()
  runs+=(playwright)
fi
if needed 'check' && ! present 'python3 -c '\''import PIL, cairosvg'\'''; then
  missing+=('Pillow and CairoSVG'); apt+=(python3-pil python3-cairosvg); brew+=(); cask+=()
  runs+=(pyimage)
fi
if needed 'check' && ! present 'command -v bwrap'; then
  missing+=('bubblewrap'); apt+=(bubblewrap); brew+=(); cask+=()
fi
if needed 'check' && ! present 'command -v rg'; then
  missing+=('ripgrep'); apt+=(ripgrep); brew+=(ripgrep); cask+=()
fi
if needed 'check' && ! present 'command -v ss'; then
  missing+=('ss'); apt+=(iproute2); brew+=(); cask+=()
fi
if needed 'check videos' && ! present 'test -x /usr/bin/google-chrome'; then
  missing+=('Google Chrome'); apt+=(); brew+=(); cask+=()
  runs+=(chrome)
fi
if needed 'check' && ! present 'test -x .toolchains/go/bin/go'; then
  missing+=('Go (checksum-pinned, in .toolchains/)'); apt+=(); brew+=(); cask+=()
  runs+=(go)
fi
if needed 'videos' && ! present 'command -v ffmpeg'; then
  missing+=('FFmpeg'); apt+=(ffmpeg); brew+=(ffmpeg); cask+=()
fi
if needed 'videos' && ! present 'video/.conda/bin/python -c '\''import manim, piper'\'''; then
  missing+=('the video environment (video/.conda: Python with Manim and Piper)'); apt+=(libcairo2-dev libpango1.0-dev pkg-config); brew+=(cairo pango pkg-config); cask+=()
  runs+=(videoenv)
fi
if needed 'tla' && ! present 'command -v java'; then
  missing+=('Java'); apt+=(default-jre-headless); brew+=(openjdk); cask+=()
fi
if needed 'tla' && ! present 'test -f .toolchains/tla/tla2tools-1.7.4.jar'; then
  missing+=('TLA+ tools (checksum-pinned, in .toolchains/)'); apt+=(); brew+=(); cask+=()
  runs+=(tlc)
fi
run_elan() {
  curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none
}
run_playwright() {
  python3 -m pip install --user playwright 2>/dev/null || python3 -m pip install --user --break-system-packages playwright
  python3 -m playwright install --with-deps chromium
}
run_pyimage() {
  python3 -c 'import PIL, cairosvg' 2>/dev/null || python3 -m pip install --user pillow cairosvg 2>/dev/null || python3 -m pip install --user --break-system-packages pillow cairosvg
}
run_chrome() {
  if command -v apt-get >/dev/null; then curl -fsSLo /tmp/leanfm-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && sudo apt-get install -y /tmp/leanfm-chrome.deb && rm -f /tmp/leanfm-chrome.deb; else echo 'install Google Chrome at /usr/bin/google-chrome'; fi
}
run_go() {
  make go-toolchain
}
run_videoenv() {
  if command -v conda >/dev/null; then conda create -y -p video/.conda python=3.11 pip && video/.conda/bin/python -m pip install manim piper-tts; else echo 'install conda (Miniforge: https://conda-forge.org/download), then run ./setup.sh videos again'; fi
}
run_tlc() {
  make tla-toolchain
}
if [ ${#missing[@]} -eq 0 ]; then [ -n "$quiet" ] || echo "ok: everything $target needs is present"; exit 0; fi
echo "missing for $target:"; printf '  %s\n' "${missing[@]}"
if [ "$mode" = check ]; then
  echo "install them with ./setup.sh $target, or have an assistant do it: make setup-help TARGET=$target"; exit 1
fi
if [ "$os" = apt ] && [ ${#apt[@]} -gt 0 ]; then sudo apt-get update && sudo apt-get install -y "${apt[@]}"; fi
if [ "$os" = mac ]; then
  command -v brew >/dev/null 2>&1 || { echo "install Homebrew first: https://brew.sh"; exit 1; }
  [ ${#brew[@]} -gt 0 ] && brew install "${brew[@]}"
  [ ${#cask[@]} -gt 0 ] && brew install --cask "${cask[@]}"
fi
if [ "$os" = other ]; then echo "no apt-get or Homebrew here: install the programs above, then run ./setup.sh --check"; fi
for r in "${runs[@]}"; do "run_$r"; done
exec "$0" "$target" --check
