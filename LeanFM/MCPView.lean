import Lean

/-! The MCP Apps view for LeanFM's logic tools (clause selfhost.mcp.logic.view, decision
logic-view). One static HTML document, compiled in; it renders a tool result's structuredContent
with text nodes and SVG geometry only, and declares no network domains. -/

namespace LeanFM.MCP
open Lean

def logicViewUri : String := "ui://leanfm/logic-view"
def logicViewMimeType : String := "text/html;profile=mcp-app"
def logicViewHtml : String := include_str "MCPView.html"

/-- The tools whose results the view draws. -/
def logicViewTools : List String := ["check_protocol", "check_ctl", "check_reassembly", "knows"]

/-- `_meta` for a tool definition that the view draws. -/
def logicViewToolMeta : Json :=
  Json.mkObj [("ui", Json.mkObj [("resourceUri", logicViewUri)])]

/-- `_meta` for the view resource: no external domains of any kind. -/
def logicViewResourceMeta : Json :=
  let none : Json := Json.arr #[]
  Json.mkObj [("ui", Json.mkObj
    [("csp", Json.mkObj [("connectDomains", none), ("resourceDomains", none),
      ("frameDomains", none), ("baseUriDomains", none)]),
     ("prefersBorder", true)])]

/-- Attach the view to a tool definition when the view draws that tool. -/
def withLogicView (tool : Json) : Json :=
  match tool.getObjValAs? String "name" with
  | .ok name => if logicViewTools.contains name then tool.setObjVal! "_meta" logicViewToolMeta else tool
  | .error _ => tool

end LeanFM.MCP
