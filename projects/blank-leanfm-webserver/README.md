# Blank reconstruction of the LeanFM web server

This is a controlled self-hosting experiment. A fresh agent receives the two
renderings of the same book plus a minimal generic LeanFM authoring and
validation distribution. It must reconstruct the requirements, implementation
specification, server, and tests without reading the original LeanFM
application repository.

The delivered result must run without Codex. Codex, Claude, Gemini, or a human
may be the construction agent; the completed server is a standalone browser
application whose users bring their own model-provider credentials.

Copy this directory outside the original checkout before beginning. Then open a
new Codex conversation in the copied directory and submit `BOOTSTRAP.md` as the
first request.

Success is not byte-for-byte reproduction. Compare the result by observable
coverage: actors, task grammars, protobuf bytes, HTTP projection, authentication,
project isolation, MCP, acceptance gates, generated views, accessibility,
concurrency, resource bounds, and tests. Missing or contradictory information
must be reported as a book defect.

The bootstrap is intentionally not an answer key. `LeanFM/` contains generic
types and validators; `bootstrap/` prints the authoritative references,
validates the conventional `LeanFMProject.Requirements` value, and renders its
task views. It contains no ChatUI actors, messages, tasks, routes, or accepted
implementation mappings.

The directories are intentionally empty until their acceptance gate permits
content:

- `Specification/`: candidate and accepted LeanFM artifacts;
- `source/`: implementation after both gates;
- `tests/`: conformance tests after both gates;
- `generated/`: prompt-derived diagrams and reports;
- `evidence/`: ambiguity log, decisions, and check results.
