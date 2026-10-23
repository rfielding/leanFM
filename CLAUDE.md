# Claude Code in LeanFM

@AGENTS.md

The shared instructions above are authoritative for this repository. Read
`SKILL.md` when they require it; keep both LeanFM acceptance gates explicit.

Start Claude with `make claude` or `bash scripts/claude.sh` so project session
history, memory, configuration, and temporary files stay under `.cache/claude/`.
Do not write credentials into instructions, MCP configuration, or tracked files.

The project `.mcp.json` connects to the existing read-only LeanFM service at
`http://127.0.0.1:8080/mcp`. Start it with `make serve` in another terminal when
needed. Use its resources and tools for canonical context, live language
references, interrogation, and validation. MCP cannot accept either gate.

For a fresh session, use `book/main.pdf`, the canonical specifications together
in `LeanFM/LLMGenerated/`, and the existing source tree. Read durable acceptance
status before editing implementation; a successful check is not acceptance.
