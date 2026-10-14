import LeanFM.Artifacts
import LeanFM.MDPDiagram

namespace MCPInteractionExample
open LeanFM

def actors := ["Codex", "LeanFM MCP", "Project"]

def messages : List MDPDiagram.InteractionMessage :=
  [ { src := "Codex", dst := "LeanFM MCP", label := "initialize(protocolVersion, capabilities)" }
  , { src := "LeanFM MCP", dst := "Codex", label := "initialized(instructions: book is durable context)" }
  , { src := "Codex", dst := "LeanFM MCP", label := "resources/read(book/main.pdf)" }
  , { src := "LeanFM MCP", dst := "Project", label := "read fixed allowlisted artifact" }
  , { src := "Project", dst := "LeanFM MCP", label := "book bytes" }
  , { src := "LeanFM MCP", dst := "Codex", label := "resource(application/pdf, base64)" }
  , { src := "Codex", dst := "LeanFM MCP", label := "tools/call(validate generated artifacts)" }
  , { src := "LeanFM MCP", dst := "Project", label := "evaluate deterministic validation reports" }
  , { src := "Project", dst := "LeanFM MCP", label := "requirements and implementation evidence" }
  , { src := "LeanFM MCP", dst := "Codex", label := "tool result(text)" } ]

def provenance : DesiredOutput :=
  { id := "selfhost.mcp.interaction"
  , prompt := "Implement MCP and document it in the book as an agent-facing interface."
  , question := "How does an agent acquire the durable book and checked project evidence without mutating acceptance state?"
  , kind := .interactionDiagram
  , eventSource := "LeanFM.MCP fixed resource and tool dispatch"
  , reducer := "project initialize, resources/read, and tools/call messages onto Codex, MCP, and project lifelines"
  , unit := "JSON-RPC messages per stateless request" }

def main : IO Unit := do
  IO.FS.writeFile "book/generated/mcp-interaction.tex"
    (MDPDiagram.renderInteractionTeX actors messages)
  IO.FS.writeFile "book/generated/mcp-interaction-provenance.txt" (reprStr provenance ++ "\n")
  IO.println "ok: MCP interaction diagram generated"

end MCPInteractionExample

def main : IO Unit := MCPInteractionExample.main
