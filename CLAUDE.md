# Claude Code in LeanFM

@AGENTS.md

The shared instructions above are authoritative for this repository. Read
`SKILL.md` when they require it. Review and acceptance happen in git, not in LeanFM.

Start Claude with `make claude` or `bash scripts/claude.sh` so project session
history, memory, configuration, and temporary files stay under `.cache/claude/`.
Do not write credentials into instructions, MCP configuration, or tracked files.

The project `.mcp.json` connects to the existing read-only LeanFM service at
`http://127.0.0.1:8080/mcp`. Start it with `make serve` in another terminal when
needed. Use its resources and tools for canonical context, live language
references, interrogation, logic consultation and validation.

For a fresh session, use `book/main.pdf`, the canonical specifications together
in `LeanFM/LLMGenerated/`, and the existing source tree. `git log` and
`git diff` show what the user has reviewed and what is still in progress.
