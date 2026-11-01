# GoServer agent instructions

This directory is the exclusive project root. Read SKILL.md, manifest.json,
book/main.pdf, book/main-dark.pdf, spec/Requirements.lean,
spec/Requirements.proto, spec/Implementation.lean, spec/ProjectMemory.md and
spec/runtime.json before implementation. Read existing source and review
reports. Conversation history is disposable and must never be required to
reconstruct goals, decisions, known failures or a PR.

Preserve the manifest identity and both protected revision-bound gates. The
current slice is rooms, chat and N-player Go with selectable bots, autopilot,
teams and merges, bot search summaries, history, variations and local analysis
(book chapter "Lab parity revision"). The N-Player Go Lab engine in
source/cmd/demo/static/engine.js is the rules reference; source/engine.go ports it.
Use live LeanFM MCP language references for the formal language, then compile
this project's actual Project.Requirements.requirements and
Project.Implementation.implementation. Host self-validation is not evidence
for this project. Keep all project inputs, code, cache and evidence here.

Application source, tests and its Makefile belong in source/. make run must
launch an actual loopback app on 8081, independently of LeanFM on 8080.
Choose sensible reversible defaults and run authorized checks without quizzing
the user about syntax or implementation machinery. Preserve security and
negative requirements. Keep exact failures and verified remedies in durable
reports and project memory. A passing startup check does not establish full
semantic refinement or close a recorded counterexample.

For PRs, obtain the real base from this repository's Git history, inspect the
actual patch, trace changes/tests to accepted requirements and report checks
and remaining gaps. Do not claim a remote PR or push exists without one.
Never commit conversations, sessions, provider keys, passwords or build caches.
