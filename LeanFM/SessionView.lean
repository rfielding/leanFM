import Lean

/-! The MCP Apps view for LeanFM's session tools (clause selfhost.mcp.session.view, decision
session-view). One static HTML document, compiled in. It draws a result's diagram from LeanFM's
shapes with createElementNS, animates its event stream on a canvas, shows every other field as
text, and edits the protocol as LeanFM protocol text, rechecking it through the host's tools/call; it
declares no network domains (editing Lean text; session_conform's problems show as issues; the animation starts simple; arrows drawn thicker than frames; text haloed). Lake does not track include_str, so a change to the HTML needs a change here too. -/

namespace LeanFM.MCP
open Lean

def sessionViewUri : String := "ui://leanfm/session-view"
def sessionViewHtml : String := include_str "SessionView.html"

/-- The tools whose results the session view draws. -/
def sessionViewTools : List String := ["session_check", "session_diagram", "session_simulate", "session_conform"]

def sessionViewToolMeta : Json :=
  Json.mkObj [("ui", Json.mkObj [("resourceUri", sessionViewUri)])]

/-- Attach the session view to a tool definition when the view draws that tool. -/
def withSessionView (tool : Json) : Json :=
  match tool.getObjValAs? String "name" with
  | .ok name => if sessionViewTools.contains name then tool.setObjVal! "_meta" sessionViewToolMeta else tool
  | .error _ => tool

end LeanFM.MCP
