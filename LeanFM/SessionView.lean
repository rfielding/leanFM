import Lean

/-! The MCP Apps view for LeanFM's session tools (clause selfhost.mcp.session.view, decision
session-view). One static HTML document, compiled in. It draws a result's diagram from LeanFM's
shapes with createElementNS, animates its event stream on a canvas, shows every other field as
text, and edits the protocol as LeanFM protocol text, rechecking it through the host's tools/call; it
declares no network domains (editing Lean text; session_conform's problems show as issues; the animation starts simple; arrows drawn thicker than frames; text haloed; walk-through via session_next; script checked with node --check; no choice symbols; counterexample and compatibility panels; a sketch that adds messages by clicking lifelines, trimming a split brace, offering replies only to requests; MDP terminal balances, expected net balances and the chain view's expected visits, outcomes and duration, walks' realized rewards and horizon totals as text; a navigation bar for the whole protocol, each role's view, its OpenAPI and protobuf, and a generated dataset drawn as bar charts; session_explore's tree on a canvas, folded at the start, opened by click or keys, panned and zoomed, with a node's source, a protocol's diagram or a role's view beside it; a dataset whose sessions each take their own order folds its path chart; room after the longest bar for its count; a message's payload, a role's state machine and the grammar walk, all on canvas; the walk keeps its panel and the camera follows it; a newer layout stops an older tween; a step taken before keeps its known edge; a protocol picked from the list draws its own diagram at once, with a state machine per role and its own grammar walk; a sequence diagram folds: a click on a frame header folds or opens it, an included protocol starts folded and can show its roles' state machines instead, a click on an actor shows its state machine, and every drawing has a collapse button; whatever is picked in the tree is drawn, its own part highlighted and the frames around it opened, and a click on an arrow or a frame header shows the source it was drawn from; in the tree a click selects a node and only its badge, a double click or Enter opens it; left and right move to the parent and into the first child, up and down among siblings; a defined protocol in the tree opens to its own steps; panels that fold say so in a header button; the diagram's clickable parts outline on hover and each actor is marked "states"; a result with no shapes falls back to its SVG). Lake does not track include_str, so a change to the HTML needs a change here too. -/

namespace LeanFM.MCP
open Lean

def sessionViewUri : String := "ui://leanfm/session-view"
def sessionViewHtml : String := include_str "SessionView.html"

/-- The tools whose results the session view draws. -/
def sessionViewTools : List String := ["session_check", "session_diagram", "session_mdp", "session_simulate", "session_conform", "session_ctl", "session_compat", "session_actor", "session_dataset", "session_openapi", "session_types", "session_explore"]

def sessionViewToolMeta : Json :=
  Json.mkObj [("ui", Json.mkObj [("resourceUri", sessionViewUri)])]

/-- Attach the session view to a tool definition when the view draws that tool. -/
def withSessionView (tool : Json) : Json :=
  match tool.getObjValAs? String "name" with
  | .ok name => if sessionViewTools.contains name then tool.setObjVal! "_meta" sessionViewToolMeta else tool
  | .error _ => tool

end LeanFM.MCP
