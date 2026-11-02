import LeanFM.Artifacts
import LeanFM.MDPDiagram

/-!
A deployment as a tree with implicit names.

The world is a tree: islands, datacenters, machines, replicated and sharded groups, actors, and
under each actor its interfaces grouped by scope (`ingress`, `peering`, `internal`, `local`).
A node's name is its path, so `us.alice.ingress.https` needs no separate declaration. The tree
does three jobs:

* reachability: a scope says who may call an interface at all (ingress: anyone; peering: any
  island; internal: the same island; local: the same machine);
* physics: the interface kind gives the conditions its protocol stack surfaces, and placement
  adds partition across islands, hostility from outside, rejection into a replicated group and
  per-key order into a shard;
* collapsed views: an interaction diagram can be drawn at any level of the tree, hiding every
  message inside one node.

Run: `lake env lean --run TopologyExample.lean`; writes book/generated/topology-*.tex.
-/

namespace TopologyExample
open LeanFM

/-! ### Conditions and the interface hierarchy -/

inductive Condition where
  | timeout | duplicate | reject | loss | reorder | perKeyOrder | partition | hostile | readable
  deriving BEq, Repr, Inhabited

def Condition.name : Condition → String
  | .timeout => "timeout" | .duplicate => "duplicate" | .reject => "reject" | .loss => "loss"
  | .reorder => "reorder" | .perKeyOrder => "per-key order" | .partition => "partition"
  | .hostile => "hostile" | .readable => "readable"

inductive IfaceKind where
  | call | queue | stream | http | api | ingressHttp | ingressHttps | datagram | topic
  deriving BEq, Repr, Inhabited

def IfaceKind.name : IfaceKind → String
  | .call => "call" | .queue => "queue" | .stream => "stream" | .http => "http" | .api => "api"
  | .ingressHttp => "ingressHttp" | .ingressHttps => "ingressHttps" | .datagram => "datagram"
  | .topic => "topic"

def IfaceKind.parent : IfaceKind → Option IfaceKind
  | .http => some .stream | .api => some .http | .ingressHttp => some .http
  | .ingressHttps => some .ingressHttp | _ => none

structure KindSpec where
  adds    : List Condition
  removes : List Condition
  masked  : String
  note    : String

def IfaceKind.spec : IfaceKind → KindSpec
  | .call         => ⟨[], [], "", "synchronous; one process"⟩
  | .queue        => ⟨[], [], "", "bounded, blocks when full; one machine"⟩
  | .stream       => ⟨[], [], "loss and reorder become latency", "TCP; a close ends the session"⟩
  | .http         => ⟨[.timeout, .duplicate], [], "", "request and response; a retry may arrive twice"⟩
  | .api          => ⟨[.reject], [], "", "a busy server answers 429 or 503"⟩
  | .ingressHttp  => ⟨[.hostile, .readable], [], "", "from outside; anyone can send or read"⟩
  | .ingressHttps => ⟨[], [.readable], "", "TLS: peer identity observable, bytes private"⟩
  | .datagram     => ⟨[.loss, .reorder, .duplicate], [], "", "UDP; nothing is hidden"⟩
  | .topic        => ⟨[.duplicate, .perKeyOrder], [], "loss becomes latency within retention",
                      "Kafka; at least once, ordered per key"⟩

def ancestors (k : IfaceKind) : List IfaceKind :=
  let rec go (fuel : Nat) (k : IfaceKind) : List IfaceKind :=
    match fuel, k.parent with
    | fuel + 1, some p => go fuel p ++ [k]
    | _, _ => [k]
  go 8 k

def kindConditions (k : IfaceKind) : List Condition :=
  (ancestors k).foldl (fun acc a =>
    let s := a.spec
    (acc.filter (fun c => !s.removes.contains c)) ++ s.adds.filter (fun c => !acc.contains c)) []

/-! ### The tree -/

inductive Scope where
  | ingress | peering | internal | local
  deriving BEq, Repr, Inhabited

def Scope.name : Scope → String
  | .ingress => "ingress" | .peering => "peering" | .internal => "internal" | .local => "local"

def Scope.reach : Scope → String
  | .ingress => "anyone, including outside" | .peering => "any island, not outside"
  | .internal => "the same island" | .local => "the same machine"

inductive BoxKind where
  | outside | island | datacenter | machine | replicated | sharded | actor
  deriving BEq, Repr, Inhabited

inductive Node where
  | box   (name : String) (kind : BoxKind) (label : String) (children : List Node)
  | actor (name : String) (ifaces : List (Scope × String × IfaceKind))

open Node in
def world : List Node :=
  [ box "outside" .outside "outside" [ actor "browser" [] ]
  , box "us" .island "us" [
      box "dc1" .datacenter "datacenter dc1" [
        box "m1" .machine "machine m1" [
          actor "alice" [(.ingress, "https", .ingressHttps), (.internal, "api", .api)] ],
        box "ledger" .replicated "replicated x3, raft" [
          actor "ledger" [(.internal, "api", .api)] ] ] ]
  , box "eu" .island "eu" [
      box "dc1" .datacenter "datacenter dc1" [
        box "m1" .machine "machine m1" [
          actor "bob" [(.ingress, "http", .ingressHttp), (.peering, "api", .api)] ],
        box "m2" .machine "machine m2" [
          actor "charles" [(.ingress, "https", .ingressHttps), (.internal, "api", .api)],
          actor "audit" [(.local, "syslog", .datagram)] ] ] ]
  , box "us+eu" .sharded "sharded by account, us and eu" [
      actor "accounts" [(.peering, "topic", .topic)] ] ]

structure Box where
  path  : List String
  kind  : BoxKind
  label : String
  deriving Inhabited

structure Leaf where
  actor : String
  path  : List String          -- the actor's box path, ending with the actor
  scope : Option Scope         -- none for an actor that exposes no interface
  name  : String
  kind  : IfaceKind
  deriving Inhabited

partial def flatten (parent : List String) : Node → List Box × List Leaf
  | .box name kind label children =>
    let path := parent ++ [name]
    children.foldl (fun (bs, ls) c => let (b, l) := flatten path c; (bs ++ b, ls ++ l))
      ([⟨path, kind, label⟩], [])
  | .actor name ifaces =>
    let path := parent ++ [name]
    let leaves := if ifaces.isEmpty then [⟨name, path, none, name, .call⟩]
      else ifaces.map (fun (s, n, k) => ⟨name, path, some s, n, k⟩)
    ([⟨path, .actor, name⟩], leaves)

def flat : List Box × List Leaf :=
  world.foldl (fun (bs, ls) n => let (b, l) := flatten [] n; (bs ++ b, ls ++ l)) ([], [])
def boxes : List Box := flat.1
def leaves : List Leaf := flat.2

def boxAt (p : List String) : Option Box := boxes.find? (·.path == p)
def actorPath (a : String) : List String := ((leaves.find? (·.actor == a)).map (·.path)).getD [a]
def island (p : List String) : String := p.headD "world"

/-- The implicit name: island, actor, scope, interface; containers in between are left out. -/
def shortName (l : Leaf) : String :=
  match l.scope with
  | none => s!"{island l.path}.{l.actor}"
  | some s => s!"{island l.path}.{l.actor}.{s.name}.{l.name}"

def commonPrefix : List String → List String → List String
  | a :: as, b :: bs => if a == b then a :: commonPrefix as bs else []
  | _, _ => []

def inKind (p : List String) (k : BoxKind) : Bool :=
  (List.range p.length).any (fun n => ((boxAt (p.take (n + 1))).map (·.kind)) == some k)

/-! ### Channels and what the tree says about them -/

structure Channel where
  src     : String
  dst     : String        -- implicit name of the receiving interface
  handles : List Condition
  deriving Inhabited

def channels : List Channel :=
  [ ⟨"browser", "us.alice.ingress.https", [.timeout, .duplicate, .hostile]⟩
  , ⟨"browser", "eu.bob.ingress.http", [.timeout, .duplicate, .hostile]⟩
  , ⟨"browser", "eu.charles.ingress.https", [.timeout, .duplicate, .hostile]⟩
  , ⟨"alice", "us.ledger.internal.api", [.timeout, .duplicate, .reject]⟩
  , ⟨"alice", "eu.bob.peering.api", [.timeout, .duplicate, .reject]⟩
  , ⟨"alice", "us+eu.accounts.peering.topic", [.duplicate, .perKeyOrder, .partition]⟩
  , ⟨"charles", "eu.audit.local.syslog", [.loss, .reorder, .duplicate]⟩
  , ⟨"charles", "us.alice.internal.api", [.timeout, .duplicate, .reject, .partition]⟩ ]

def leafNamed (n : String) : Leaf := (leaves.find? (fun l => shortName l == n)).getD default

def reachable (srcActor : String) (l : Leaf) : Bool :=
  let s := actorPath srcActor
  let c := commonPrefix s l.path
  let fromOutside := island s == "outside"
  match l.scope with
  | none => true
  | some .ingress => true
  | some .peering => !fromOutside
  | some .internal => !fromOutside && !c.isEmpty
  | some .local => (c.length ≥ 1) && ((boxAt c).map (fun b => b.kind == .machine || b.kind == .actor)).getD false

def placement (c : Channel) : List Condition :=
  let l := leafNamed c.dst
  let s := actorPath c.src
  let outside := island s == "outside" || island l.path == "outside"
  (if (commonPrefix s l.path).isEmpty && !outside then [Condition.partition] else []) ++
  (if outside then [Condition.hostile] else []) ++
  (if inKind l.path .replicated then [Condition.reject] else []) ++
  (if inKind l.path .sharded then [Condition.perKeyOrder] else [])

def derived (c : Channel) : List Condition :=
  let base := kindConditions (leafNamed c.dst).kind
  base ++ (placement c).filter (fun x => !base.contains x)

def missing (c : Channel) : List Condition := (derived c).filter (fun x => !c.handles.contains x)
def blocked (c : Channel) : Bool := !reachable c.src (leafNamed c.dst)
def bad (c : Channel) : Bool := blocked c || !(missing c).isEmpty

/-! ### A scenario, for collapsed interaction diagrams -/

structure Msg where
  id    : String
  src   : String
  dst   : String
  label : String
  cause : Option String
  deriving Inhabited

def scenario : List Msg :=
  [ ⟨"o",  "browser", "alice",    "POST /orders",   none⟩
  , ⟨"r1", "alice",   "ledger",   "reserve(item)",  some "o"⟩
  , ⟨"r2", "ledger",  "alice",    "reserved",       some "r1"⟩
  , ⟨"d",  "alice",   "accounts", "debit(account)", some "r2"⟩
  , ⟨"s",  "alice",   "bob",      "ship(order)",    some "r2"⟩
  , ⟨"s2", "bob",     "alice",    "shipped",        some "s"⟩
  , ⟨"c",  "alice",   "browser",  "201 Created",    some "s2"⟩ ]

def tex (s : String) : String :=
  s.foldl (fun acc ch => acc ++ match ch with
    | '_' => "\\_" | '&' => "\\&" | '%' => "\\%" | '#' => "\\#" | _ => ch.toString) ""

/-! ### Rendering the tree -/

def fmt (x : Float) : String := toString ((x * 100).round / 100)

def boxKey (b : Box) : String := "/".intercalate b.path

def boxChain (l : Leaf) : List Box :=
  (List.range l.path.length).filterMap (fun n => boxAt (l.path.take (n + 1)))

def boxHeight (b : Box) : Nat :=
  let rec go (fuel : Nat) (p : List String) : Nat :=
    match fuel with
    | 0 => 1
    | fuel + 1 =>
      let kids := boxes.filter (fun c => c.path.length == p.length + 1 && c.path.take p.length == p)
      1 + (kids.map (fun k => go fuel k.path)).foldl max 0
  go 16 b.path

def leafCount : Nat := leaves.length
def leafAt (i : Nat) : Leaf := leaves.getD i default
def firstLeaf (b : Box) : Nat := (leaves.findIdx? (fun l => l.path.take b.path.length == b.path)).getD 0
def lastLeaf (b : Box) : Nat :=
  ((List.range leafCount).filter (fun i => (leafAt i).path.take b.path.length == b.path)).getLast?.getD 0
def opensAt (i : Nat) : List Box := (boxChain (leafAt i)).filter (fun b => firstLeaf b == i)
def closesAt (i : Nat) : List Box := (boxChain (leafAt i)).filter (fun b => lastLeaf b == i)

def rowGap : Float := 0.72
def levelGap : Float := 0.4
def leafW : Float := 4.6
def marginStep : Float := 0.24

def ys : List Float :=
  (List.range leafCount).foldl (fun acc i =>
    match acc.getLast? with
    | none => [0.0]
    | some y => acc ++ [y - rowGap - levelGap * ((closesAt (i - 1)).length + (opensAt i).length).toFloat]) []
def yOf (i : Nat) : Float := ys.getD i 0.0

def boxTeX (b : Box) : String :=
  let f := firstLeaf b; let l := lastLeaf b
  let inside (x : Box) := x.path.take b.path.length == b.path
  let rankOpen := ((opensAt f).filter inside).length
  let rankClose := ((closesAt l).filter inside).length
  let top := yOf f + 0.3 + levelGap * rankOpen.toFloat
  let bot := yOf l - 0.3 - levelGap * (rankClose.toFloat - 1.0) - 0.1
  let m := marginStep * (boxHeight b).toFloat
  let style := match b.kind with
    | .outside => "topobox, dashed" | .island => "topobox, very thick" | .datacenter => "topobox, thick"
    | .replicated => "topobox, double" | .sharded => "topobox, densely dotted, thick"
    | .actor => "topobox, fill=diagramgroup" | _ => "topobox"
  let label := if b.kind == .actor then s!"\\textbf\{{tex b.label}}" else tex b.label
  s!"\\draw[{style}] ({fmt (-m)},{fmt bot}) rectangle ({fmt (leafW + m)},{fmt top});\n" ++
  s!"\\node[topolabel] at ({fmt (-m + 0.08)},{fmt (top - 0.03)}) \{{label}};\n"

def leafTeX (i : Nat) : String :=
  let l := leafAt i
  s!"\\node[topoleaf] (L{i}) at (0,{fmt (yOf i)}) \{\\texttt\{{tex (shortName l)}}};\n"

def maxMargin : Float := marginStep * (boxes.map (fun b => (boxHeight b).toFloat)).foldl max 0

def srcLeaf (a : String) : Nat := (leaves.findIdx? (·.actor == a)).getD 0
def dstLeaf (n : String) : Nat := (leaves.findIdx? (fun l => shortName l == n)).getD 0

def edgeTeX (j : Nat) (c : Channel) : String :=
  let s := srcLeaf c.src; let d := dstLeaf c.dst
  let x := leafW + maxMargin + 0.45 + 0.5 * j.toFloat
  let sy := yOf s + 0.1 - 0.05 * (j % 4).toFloat
  let dy := yOf d - 0.1
  let style := if bad c then "topobad" else "topook"
  s!"\\draw[{style}] ({fmt leafW},{fmt sy}) -- ({fmt x},{fmt sy}) -- ({fmt x},{fmt dy}) -- ({fmt leafW},{fmt dy});\n" ++
  s!"\\node[topotag{if bad c then ", topobadtag" else ""}] at ({fmt x},{fmt ((sy + dy) / 2)}) \{{j + 1}};\n"

def graphTeX : String :=
  "% Generated by TopologyExample.lean.\n\\begin{tikzpicture}[>=Latex,\n" ++
  "  topobox/.style={draw=diagramink!55,rounded corners=3pt},\n" ++
  "  topolabel/.style={anchor=north west,font=\\scriptsize\\itshape,text=diagramink!85,inner sep=1pt},\n" ++
  "  topoleaf/.style={anchor=west,draw=diagramink!70,fill=diagramblue,rounded corners=2pt,minimum width=" ++ fmt leafW ++ "cm,minimum height=.4cm,font=\\scriptsize,inner sep=2pt},\n" ++
  "  topook/.style={->,thick,draw=leangreen},\n" ++
  "  topobad/.style={->,very thick,draw=red!75!diagramink},\n" ++
  "  topotag/.style={circle,fill=diagramsurface,draw=leangreen,font=\\tiny\\bfseries,inner sep=1pt,minimum size=.36cm},\n" ++
  "  topobadtag/.style={draw=red!75!diagramink,text=red!75!diagramink}]\n" ++
  String.join (boxes.map boxTeX) ++
  String.join ((List.range leafCount).map leafTeX) ++
  String.join ((List.range channels.length).map (fun j => edgeTeX j (channels.getD j default))) ++
  "\\end{tikzpicture}\n"

def conds (cs : List Condition) : String :=
  if cs.isEmpty then "--" else ", ".intercalate (cs.map (·.name))

def red (s : String) : String := s!"\\textcolor\{red!75!diagramink}\{{s}}"

def tableTeX : String :=
  let rows := (List.range channels.length).map (fun j =>
    let c := channels.getD j default
    let l := leafNamed c.dst
    let verdict :=
      if blocked c then red s!"not reachable: {(l.scope.map Scope.name).getD ""} to {island l.path}"
      else if (missing c).isEmpty then "handled" else red s!"unhandled: {conds (missing c)}"
    s!"{j + 1} & {tex c.src} & \\texttt\{{tex c.dst}} & {conds (derived c)} & {verdict} \\\\\n")
  "% Generated by TopologyExample.lean.\n\\begin{tabular}{@{}rlp{.31\\textwidth}p{.24\\textwidth}p{.19\\textwidth}@{}}\n\\toprule\n" ++
  "& from & to & conditions surfaced & verdict \\\\\n\\midrule\n" ++ String.join rows ++
  "\\bottomrule\n\\end{tabular}\n"

def hierarchyTeX : String :=
  let order : List IfaceKind := [.call, .queue, .stream, .http, .api, .ingressHttp, .ingressHttps, .datagram, .topic]
  let rows := order.map (fun k =>
    let depth := (ancestors k).length - 1
    let s := k.spec
    let indent := if depth == 0 then "" else s!"\\hspace*\{{fmt (0.9 * depth.toFloat)}em}$\\hookrightarrow$\\,"
    let delta := (s.adds.map (fun c => "+" ++ c.name)) ++ (s.removes.map (fun c => "$-$" ++ c.name))
    s!"{indent}\\texttt\{{k.name}} & {if delta.isEmpty then "--" else ", ".intercalate delta} & {if s.masked.isEmpty then "--" else s.masked} & {s.note} \\\\\n")
  "% Generated by TopologyExample.lean.\n\\begin{tabular}{@{}p{.25\\textwidth}p{.2\\textwidth}p{.19\\textwidth}p{.27\\textwidth}@{}}\n\\toprule\n" ++
  "kind & surfaces & hidden as latency & notes \\\\\n\\midrule\n" ++ String.join rows ++
  "\\bottomrule\n\\end{tabular}\n"

/-- Which scopes of each top-level subtree are reachable from each other one, computed from the
actors and interfaces actually in the tree. -/
def reachTeX : String :=
  let tops := (boxes.filter (·.path.length == 1)).map (·.path.headD "")
  let actorsIn (t : String) := ((leaves.filter (fun l => island l.path == t)).map (·.actor)).eraseDups
  let cell (a b : String) : String :=
    let ss := (leaves.filter (fun l => island l.path == b && l.scope.isSome &&
      (actorsIn a).any (fun x => x != l.actor && reachable x l))).filterMap (·.scope)
    let names := ss.foldl (fun acc s => if acc.contains s.name then acc else acc ++ [s.name]) []
    if names.isEmpty then "--" else ", ".intercalate names
  "% Generated by TopologyExample.lean.\n\\begin{tabular}{@{}l" ++ String.join (tops.map (fun _ => "l")) ++ "@{}}\n\\toprule\n" ++
  "from $\\backslash$ to & " ++ " & ".intercalate (tops.map (fun t => s!"\\texttt\{{tex t}}")) ++ " \\\\\n\\midrule\n" ++
  String.join (tops.map (fun a => s!"\\texttt\{{tex a}} & " ++ " & ".intercalate (tops.map (fun b => cell a b)) ++ " \\\\\n")) ++
  "\\bottomrule\n\\end{tabular}\n"

/-! ### Collapsing: boundary messages, paired into calls and returns by `cause` -/

/-- The node an actor belongs to when the tree is cut at `depth` (0 = actors themselves). -/
def nodeAt (depth : Nat) (a : String) : String :=
  if depth == 0 then a else ".".intercalate ((actorPath a).take depth)

def msgById (id : String) : Option Msg := scenario.find? (·.id == id)

def causeChain (m : Msg) : List Msg :=
  let rec go (fuel : Nat) (c : Option String) : List Msg :=
    match fuel, c.bind msgById with
    | fuel + 1, some p => p :: go fuel p.cause
    | _, _ => []
  go 32 m.cause

structure Step where
  msg     : Msg
  src     : String
  dst     : String
  answers : Option String   -- the boundary request this message returns, found through `cause`
  deriving Inhabited

/-- Messages that cross a node boundary at `depth`. A crossing message from X to Y is the return
of the nearest unanswered crossing request from Y to X in its cause chain; everything between
them, inside X, is hidden. -/
def crossings (depth : Nat) : List Step :=
  scenario.foldl (fun (acc : List Step) m =>
    let (x, y) := (nodeAt depth m.src, nodeAt depth m.dst)
    if x == y then acc else
      let answered := acc.filterMap (·.answers)
      let req := (causeChain m).find? (fun p =>
        nodeAt depth p.src == y && nodeAt depth p.dst == x && !answered.contains p.id &&
        acc.any (fun st => st.msg.id == p.id && st.answers.isNone))
      acc ++ [⟨m, x, y, req.map (·.id)⟩]) []

def lifelines (steps : List Step) : List String :=
  steps.foldl (fun acc st => (if acc.contains st.src then acc else acc ++ [st.src]) |> fun a =>
    if a.contains st.dst then a else a ++ [st.dst]) []

/-- Interaction diagram with calls solid, returns dashed, and an activation bar on the callee
spanning each call to its return. -/
def callDiagramTeX (steps : List Step) : String :=
  let ls := lifelines steps
  let col (n : String) : Float := 3.4 * ((ls.findIdx? (· == n)).getD 0).toFloat
  let row (i : Nat) : Float := -0.75 * (i + 1).toFloat
  let n := steps.length
  let bars := (List.range n).filterMap (fun i =>
    let st := steps.getD i default
    match (List.range n).find? (fun j => (steps.getD j default).answers == some st.msg.id) with
    | some j => some s!"\\fill[diagramblue,draw=leanblue] ({fmt (col st.dst - 0.09)},{fmt (row i)}) rectangle ({fmt (col st.dst + 0.09)},{fmt (row j)});\n"
    | none => none)
  let arrows := (List.range n).map (fun i =>
    let st := steps.getD i default
    let style := if st.answers.isSome then "callret" else "callreq"
    s!"\\draw[{style}] ({fmt (col st.src)},{fmt (row i)}) -- node[above,fill=pagebackground,inner sep=1pt,text=diagramink,font=\\scriptsize] \{{tex st.msg.label}} ({fmt (col st.dst)},{fmt (row i)});\n")
  "% Generated by TopologyExample.lean.\n\\begin{tikzpicture}[callreq/.style={->,>=Stealth,thick,draw=leanblue},callret/.style={->,>=Stealth,thick,dashed,draw=leangreen},life/.style={draw=diagramink,text=diagramink,fill=diagramsurface,rounded corners,minimum width=2.2cm,minimum height=6mm,font=\\small\\ttfamily}]\n" ++
  String.join (ls.map (fun l =>
    s!"\\node[life] at ({fmt (col l)},0) \{{tex l}};\n\\draw[dashed,draw=diagramink!60] ({fmt (col l)},-0.3) -- ({fmt (col l)},{fmt (row n - 0.4)});\n")) ++
  String.join bars ++ String.join arrows ++ "\\end{tikzpicture}\n"

/-- A node's local type at `depth`, as a production: the messages crossing its boundary, with
calls it makes folded into `call ... returns ...` and calls it serves into `on ... { } return`. -/
def localType (depth : Nat) (node : String) : String :=
  let steps := (crossings depth).filter (fun st => st.src == node || st.dst == node)
  let returnOf (id : String) := steps.find? (·.answers == some id)
  let pad (d : Nat) := String.ofList (List.replicate (2 * d + 2) ' ')
  let (lines, _) := steps.foldl (fun (acc : List String × Nat) st =>
    let (ls, d) := acc
    if st.dst == node && st.answers.isNone then
      match returnOf st.msg.id with
      | some _ => (ls ++ [s!"{pad d}on {st.src}: {st.msg.label} \{"], d + 1)
      | none => (ls ++ [s!"{pad d}on {st.src}: {st.msg.label}"], d)
    else if st.src == node && st.answers.isNone then
      match returnOf st.msg.id with
      | some r => (ls ++ [s!"{pad d}call {st.dst}: {st.msg.label} returns {r.msg.label}"], d)
      | none => (ls ++ [s!"{pad d}send {st.dst}: {st.msg.label}"], d)
    else if st.src == node then
      (ls ++ [s!"{pad (d - 1)}} return {st.msg.label}"], d - 1)
    else (ls, d)) ([], 0)
  -- a served call whose body is empty reads as one line
  let merged := lines.foldl (fun (acc : List String) l =>
    match acc.getLast? with
    | some p => if p.endsWith " {" && (l.trimAscii.toString.startsWith "} return") then
        acc.dropLast ++ [(p.dropEnd 2).toString ++ " " ++ ((l.trimAscii.toString).drop 2).toString]
      else acc ++ [l]
    | none => [l]) []
  s!"{node} ::=\n" ++ "\n".intercalate merged

def localTypesTeX (depth : Nat) : String :=
  let nodes := lifelines (crossings depth)
  "\\begin{lstlisting}[language={}]\n" ++ "\n\n".intercalate (nodes.map (localType depth)) ++ "\n\\end{lstlisting}\n"

def output : DesiredOutput :=
  { id := "topology.tree"
  , prompt := "Implicit tree naming that constrains what can talk to what at a high level; collapsed interaction diagrams."
  , question := "Which interfaces may each actor reach, which conditions does each channel surface, and what does one scenario look like when the tree is collapsed to islands?"
  , kind := .interactionDiagram
  , eventSource := "the tree, channels and scenario declared in TopologyExample.lean"
  , reducer := "name nodes by path; check scope reachability; inherit conditions down the interface hierarchy and add placement conditions; subtract handled conditions; collapse scenario endpoints to a tree depth, drop messages inside one node, pair each crossing message with the request it returns through its cause chain, and fold each node's crossings into a production"
  , unit := "interfaces, channels and scenario messages" }

def main : IO Unit := do
  IO.FS.writeFile "book/generated/topology-graph.tex" graphTeX
  IO.FS.writeFile "book/generated/topology-channels.tex" tableTeX
  IO.FS.writeFile "book/generated/topology-hierarchy.tex" hierarchyTeX
  IO.FS.writeFile "book/generated/topology-reach.tex" reachTeX
  IO.FS.writeFile "book/generated/topology-collapsed-islands.tex" (callDiagramTeX (crossings 1))
  IO.FS.writeFile "book/generated/topology-collapsed-actors.tex" (callDiagramTeX (crossings 0))
  IO.FS.writeFile "book/generated/topology-local-types.tex" (localTypesTeX 1)
  IO.FS.writeFile "book/generated/topology-provenance.txt" (reprStr output ++ "\n")
  IO.println s!"ok: {leaves.length} interfaces, {channels.length} channels, {(channels.filter bad).length} findings; islands view {(crossings 1).length} of {scenario.length} messages"

end TopologyExample

def main : IO Unit := TopologyExample.main
