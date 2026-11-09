import Lean

/-! The MCP Apps view for LeanFM's session tools (clause selfhost.mcp.session.view, decision
session-view). One static HTML document, compiled in. It draws a result's diagram from LeanFM's
shapes with createElementNS, animates its event stream on a canvas, and shows every other field as
text; it declares no network domains. -/

namespace LeanFM.MCP
open Lean

def sessionViewUri : String := "ui://leanfm/session-view"
def sessionViewHtml : String := include_str "SessionView.html"

/-- The tools whose results the session view draws. -/
def sessionViewTools : List String := ["session_check", "session_diagram", "session_simulate"]

def sessionViewToolMeta : Json :=
  Json.mkObj [("ui", Json.mkObj [("resourceUri", sessionViewUri)])]

/-- Attach the session view to a tool definition when the view draws that tool. -/
def withSessionView (tool : Json) : Json :=
  match tool.getObjValAs? String "name" with
  | .ok name => if sessionViewTools.contains name then tool.setObjVal! "_meta" sessionViewToolMeta else tool
  | .error _ => tool

end LeanFM.MCP
