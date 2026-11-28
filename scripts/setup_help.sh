#!/usr/bin/env bash
# make setup-help (clause selfhost.setup): what a target is missing, as a prompt for whatever assistant
# the person uses (Claude, Codex, ChatGPT in an editor, ...). Needs only bash: Python or Lean may be
# what is missing. With an agent command named, runs it interactively with the prompt as its argument;
# never guesses one. Usage: setup_help.sh TARGET [AGENT]
set -o pipefail
cd "$(dirname "$0")/.."
target=${1:-build}; agent=${2:-}
if ./setup.sh "$target" --check --quiet >/dev/null; then echo "ok: everything $target needs is present"; exit 0; fi
mkdir -p .cache/setup
prompt=.cache/setup/prompt.md
{
  echo "# Set up LeanFM's \`$target\` target on this machine"
  echo
  echo "This is a LeanFM checkout at $(pwd). \`./setup.sh $target --check\` reports:"
  echo '```'; ./setup.sh "$target" --check; echo '```'
  echo
  echo "This machine:"
  echo '```'; uname -a; [ -r /etc/os-release ] && cat /etc/os-release; [ "$(uname)" = Darwin ] && sw_vers; echo '```'
  echo
  echo "What \`$target\` needs, each with the test that says it is present and how LeanFM's list installs it:"
  echo '```'; ./setup.sh "$target" --list; echo '```'
  echo
  echo "Please:"
  echo "1. Try \`./setup.sh $target\` first; it installs only what is missing."
  echo "2. For whatever is still missing, find the right way to install it on this machine (the commands above may not fit it)."
  echo "3. Install only what is missing. Ask me before running any command that needs sudo or changes the system."
  echo "4. Finish by running \`./setup.sh $target --check\`, and tell me what you installed and anything still missing."
} > "$prompt"
if [ -z "$agent" ]; then
  echo "wrote $prompt: give it to your assistant, or run one with it: make setup-help TARGET=$target AGENT=claude (or codex, ...)"
  exit 1
fi
command -v "$agent" >/dev/null || { echo "AGENT=$agent is not a command on this machine; $prompt has the prompt"; exit 1; }
exec "$agent" "$(cat "$prompt")"
