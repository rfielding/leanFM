import Lean.Data.Json

/-! Every program outside the repository that LeanFM's make targets and scripts need, in one list
(clause selfhost.setup), and the setup script generated from it.

`./setup.sh` is `script`, written by SetupScript.lean and tracked in git; tool setup_script answers
the same text. Each entry has a shell test that succeeds when the program is present, so the script
installs only what is missing. -/

namespace LeanFM.Deps
open Lean

structure Dep where
  /-- a short identifier, also the shell function's suffix -/
  id : String
  name : String
  purpose : String
  /-- build, book, check, videos -/
  targets : List String
  /-- succeeds when present -/
  test : String
  apt : List String := []
  brew : List String := []
  brewCask : List String := []
  /-- commands to run (after the packages) when no package provides it -/
  run : String := ""
  /-- the programs it provides, as scripts and the Makefile call them -/
  provides : List String := []

def targets : List String := ["build", "book", "check", "videos", "tla"]

/-- What a target needs: book and check include build, check includes book. -/
def expand : String → List String
  | "build" => ["build"]
  | "book" => ["build", "book"]
  | "check" => ["build", "book", "check"]
  | "videos" => ["build", "videos"]
  | "tla" => ["build", "tla"]
  | _ => targets

def deps : List Dep :=
  [ { id := "git", name := "git", purpose := "the repository", targets := ["build"], test := "command -v git",
      apt := ["git"], brew := ["git"], provides := ["git"] }
  , { id := "make", name := "make", purpose := "the make targets", targets := ["build"], test := "command -v make",
      apt := ["make"], brew := ["make"], provides := ["make"] }
  , { id := "flock", name := "flock", purpose := "one make at a time in a checkout", targets := ["build"],
      test := "command -v flock", apt := ["util-linux"], brew := ["flock"], provides := ["flock"] }
  , { id := "curl", name := "curl", purpose := "downloads (elan, Go)", targets := ["build"], test := "command -v curl",
      apt := ["curl", "ca-certificates"], brew := ["curl"], provides := ["curl"] }
  , { id := "python", name := "Python 3 with pip", purpose := "the scripts and checks", targets := ["build"],
      test := "command -v python3 && python3 -m pip --version", apt := ["python3", "python3-pip"], brew := ["python"],
      provides := ["python3"] }
  , { id := "node", name := "Node.js 18 or later and npm", purpose := "the viewer's bundle (ui/)", targets := ["build"],
      test := "node -e 'process.exit(+process.versions.node.split(\".\")[0] >= 18 ? 0 : 1)' && command -v npm",
      apt := ["nodejs", "npm"], brew := ["node"], provides := ["node", "npm", "npx"] }
  , { id := "elan", name := "elan (Lean and Lake)", purpose := "builds LeanFM; installs the Lean in lean-toolchain by itself",
      targets := ["build"], test := "command -v lake || test -x \"$HOME/.elan/bin/lake\"",
      run := "curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none",
      provides := ["lake", "lean", "elan"] }
  , { id := "tex", name := "TeX Live", purpose := "the book's PDFs", targets := ["book"],
      test := "command -v pdflatex && command -v bibtex && command -v makeindex && kpsewhich pgfplots.sty tgheros.sty",
      apt := ["texlive-latex-extra", "texlive-pictures", "texlive-science", "texlive-fonts-recommended", "texlive-fonts-extra",
        "texlive-bibtex-extra"], brewCask := ["mactex-no-gui"], provides := ["pdflatex", "bibtex", "makeindex", "kpsewhich"] }
  , { id := "graphviz", name := "Graphviz", purpose := "the book's graphs", targets := ["book"], test := "command -v dot",
      apt := ["graphviz"], brew := ["graphviz"], provides := ["dot"] }
  , { id := "poppler", name := "Poppler utilities", purpose := "the book's pages in the viewer and the PDF checks",
      targets := ["book"], test := "command -v pdftoppm && command -v pdftotext && command -v pdfinfo",
      apt := ["poppler-utils"], brew := ["poppler"], provides := ["pdftoppm", "pdftotext", "pdfinfo"] }
  , { id := "playwright", name := "Playwright with Chromium", purpose := "SVG to PDF for the book, and the viewer checks",
      targets := ["book"], test := "python3 -c 'import playwright' && test -n \"$(ls -d \"$HOME\"/.cache/ms-playwright/chromium-* \"$HOME\"/Library/Caches/ms-playwright/chromium-* 2>/dev/null)\"",
      run := "python3 -m pip install --user playwright 2>/dev/null || python3 -m pip install --user --break-system-packages playwright\npython3 -m playwright install --with-deps chromium" }
  , { id := "pyimage", name := "Pillow and CairoSVG", purpose := "the chat UI's image checks", targets := ["check"],
      test := "python3 -c 'import PIL, cairosvg'", apt := ["python3-pil", "python3-cairosvg"],
      run := "python3 -c 'import PIL, cairosvg' 2>/dev/null || python3 -m pip install --user pillow cairosvg 2>/dev/null || python3 -m pip install --user --break-system-packages pillow cairosvg" }
  , { id := "bwrap", name := "bubblewrap", purpose := "the sandbox the checks run generated code in", targets := ["check"],
      test := "command -v bwrap", apt := ["bubblewrap"], provides := ["bwrap"] }
  , { id := "ripgrep", name := "ripgrep", purpose := "the checks' searches", targets := ["check"], test := "command -v rg",
      apt := ["ripgrep"], brew := ["ripgrep"], provides := ["rg"] }
  , { id := "ss", name := "ss", purpose := "finding a running server's port", targets := ["check"],
      test := "command -v ss", apt := ["iproute2"], provides := ["ss"] }
  , { id := "chrome", name := "Google Chrome", purpose := "the headless viewer in make run-log-check and the videos",
      targets := ["check", "videos"], test := "test -x /usr/bin/google-chrome",
      run := "if command -v apt-get >/dev/null; then curl -fsSLo /tmp/leanfm-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && sudo apt-get install -y /tmp/leanfm-chrome.deb && rm -f /tmp/leanfm-chrome.deb; else echo 'install Google Chrome at /usr/bin/google-chrome'; fi",
      provides := ["google-chrome"] }
  , { id := "go", name := "Go (checksum-pinned, in .toolchains/)", purpose := "the Go example's checks", targets := ["check"],
      test := "test -x .toolchains/go/bin/go", run := "make go-toolchain", provides := ["go"] }
  , { id := "ffmpeg", name := "FFmpeg", purpose := "the videos", targets := ["videos"], test := "command -v ffmpeg",
      apt := ["ffmpeg"], brew := ["ffmpeg"], provides := ["ffmpeg"] }
  , { id := "java", name := "Java", purpose := "TLC, for the TLA+ comparison (make tla-check)", targets := ["tla"],
      test := "command -v java", apt := ["default-jre-headless"], brew := ["openjdk"], provides := ["java"] }
  , { id := "tlc", name := "TLA+ tools (checksum-pinned, in .toolchains/)", purpose := "the TLA+ comparison",
      targets := ["tla"], test := "test -f .toolchains/tla/tla2tools-1.7.4.jar", run := "make tla-toolchain" } ]

def shQuote (s : String) : String := "'" ++ s.replace "'" "'\\''" ++ "'"

/-- The setup script: installs what a target needs and its tests find missing. -/
def script : String := Id.run do
  let mut out := "#!/usr/bin/env bash
# LeanFM's setup (clause selfhost.setup), generated from LeanFM/Deps.lean by SetupScript.lean: do not edit.
# Usage: ./setup.sh [build|book|check|videos|tla|all] [--check]
#   installs what the target needs and is missing (build unless named; book and check include build);
#   --check only reports what is missing, and exits 1 when something is.
set -o pipefail
cd \"$(dirname \"$0\")\"
target=build; mode=install
for a in \"$@\"; do
  case \"$a\" in
    --check) mode=check ;;
    build|book|check|videos|tla|all) target=$a ;;
    *) echo \"usage: ./setup.sh [build|book|check|videos|tla|all] [--check]\"; exit 2 ;;
  esac
done
case \"$target\" in
  build) want=\" build \" ;; book) want=\" build book \" ;; check) want=\" build book check \" ;;
  videos) want=\" build videos \" ;; tla) want=\" build tla \" ;; *) want=\" build book check videos tla \" ;;
esac
if [ \"$(uname)\" = Darwin ]; then os=mac; elif command -v apt-get >/dev/null 2>&1; then os=apt; else os=other; fi
export PATH=\"$HOME/.elan/bin:$PATH\"
needed() { for t in $1; do case \"$want\" in *\" $t \"*) return 0 ;; esac; done; return 1; }
present() { ( eval \"$1\" ) >/dev/null 2>&1; }
missing=(); apt=(); brew=(); cask=(); runs=()
"
  for d in deps do
    out := out ++ s!"if needed {shQuote (" ".intercalate d.targets)} && ! present {shQuote d.test}; then\n"
    out := out ++ s!"  missing+=({shQuote d.name}); apt+=({" ".intercalate d.apt}); brew+=({" ".intercalate d.brew}); cask+=({" ".intercalate d.brewCask})\n"
    if !d.run.isEmpty then out := out ++ s!"  runs+=({d.id})\n"
    out := out ++ "fi\n"
  for d in deps do
    if !d.run.isEmpty then
      out := out ++ s!"run_{d.id}() \{\n{"\n".intercalate ((d.run.splitOn "\n").map ("  " ++ ·))}\n}\n"
  out := out ++ "if [ ${#missing[@]} -eq 0 ]; then echo \"ok: everything $target needs is present\"; exit 0; fi
echo \"missing for $target:\"; printf '  %s\\n' \"${missing[@]}\"
if [ \"$mode\" = check ]; then echo \"run ./setup.sh $target to install them\"; exit 1; fi
if [ \"$os\" = apt ] && [ ${#apt[@]} -gt 0 ]; then sudo apt-get update && sudo apt-get install -y \"${apt[@]}\"; fi
if [ \"$os\" = mac ]; then
  command -v brew >/dev/null 2>&1 || { echo \"install Homebrew first: https://brew.sh\"; exit 1; }
  [ ${#brew[@]} -gt 0 ] && brew install \"${brew[@]}\"
  [ ${#cask[@]} -gt 0 ] && brew install --cask \"${cask[@]}\"
fi
if [ \"$os\" = other ]; then echo \"no apt-get or Homebrew here: install the programs above, then run ./setup.sh --check\"; fi
for r in \"${runs[@]}\"; do \"run_$r\"; done
exec \"$0\" \"$target\" --check
"
  return out

/-- The list for a target, as JSON for the MCP tool. -/
def listing (target : String) : Json :=
  let ts := expand target
  Json.arr <| (deps.filter (fun d => d.targets.any ts.contains)).toArray.map fun d =>
    Json.mkObj [("name", Json.str d.name), ("purpose", Json.str d.purpose), ("targets", toJson d.targets),
      ("test", Json.str d.test), ("apt", toJson d.apt), ("brew", toJson (d.brew ++ d.brewCask.map ("--cask " ++ ·))),
      ("run", Json.str d.run)]

/-- The README's install table. -/
def table : String :=
  "| Program | For | Needed by |\n|---|---|---|\n" ++
  String.join (deps.map fun d => s!"| {d.name} | {d.purpose} | {", ".intercalate d.targets} |\n")

end LeanFM.Deps
