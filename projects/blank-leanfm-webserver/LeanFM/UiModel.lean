namespace LeanFM

def joinWithComma : List String -> String
  | [] => ""
  | [x] => x
  | x :: xs => x ++ "," ++ joinWithComma xs

def joinWithNewline : List String -> String
  | [] => ""
  | [x] => x
  | x :: xs => x ++ "\n" ++ joinWithNewline xs

def jsonEscape (s : String) : String :=
  String.join <| s.toList.map fun c =>
    if c == '"' then "\\\""
    else if c == '\\' then "\\\\"
    else if c == '\n' then "\\n"
    else if c == '\r' then "\\r"
    else if c == '\t' then "\\t"
    else c.toString

def jsonString (s : String) : String :=
  "\"" ++ jsonEscape s ++ "\""

def jsonList (items : List String) : String :=
  "[" ++ joinWithComma items ++ "]"

structure AggregateNode where
  id : String
  group : String
  sub : String
  task : String
  auth : String
  terminal : Bool
  q : Nat
  label : String
deriving Repr

structure AggregateEdge where
  src : String
  dst : String
  label : String
deriving Repr

structure AggregateGraphData where
  nodes : List AggregateNode
  edges : List AggregateEdge
deriving Repr

def boolJson (b : Bool) : String :=
  if b then "true" else "false"

def aggregateNodeJson (n : AggregateNode) : String :=
  "{" ++
  "\"id\":" ++ jsonString n.id ++ "," ++
  "\"group\":" ++ jsonString n.group ++ "," ++
  "\"sub\":" ++ jsonString n.sub ++ "," ++
  "\"task\":" ++ jsonString n.task ++ "," ++
  "\"auth\":" ++ jsonString n.auth ++ "," ++
  "\"terminal\":" ++ boolJson n.terminal ++ "," ++
  "\"q\":" ++ toString n.q ++ "," ++
  "\"label\":" ++ jsonString n.label ++
  "}"

def aggregateEdgeJson (e : AggregateEdge) : String :=
  "{" ++
  "\"src\":" ++ jsonString e.src ++ "," ++
  "\"dst\":" ++ jsonString e.dst ++ "," ++
  "\"label\":" ++ jsonString e.label ++
  "}"

def aggregateGraphJson (g : AggregateGraphData) : String :=
  "{" ++
  "\"nodes\":" ++ jsonList (g.nodes.map aggregateNodeJson) ++ "," ++
  "\"edges\":" ++ jsonList (g.edges.map aggregateEdgeJson) ++
  "}"

def aggregateNodeIds (g : AggregateGraphData) : List String :=
  g.nodes.map (fun n => n.id)

def duplicateStrings : List String -> List String
  | [] => []
  | x :: xs =>
      let rest := duplicateStrings xs
      if xs.contains x && !rest.contains x then x :: rest else rest

def validateAggregateGraph (g : AggregateGraphData) : List String :=
  let ids := aggregateNodeIds g
  let duplicateIdErrors :=
    (duplicateStrings ids).map fun id => "duplicate node id: " ++ id
  let nodeErrors :=
    g.nodes.filterMap fun n =>
      if n.id == "" then some "node has empty id"
      else if n.group == "" then some ("node " ++ n.id ++ " has empty group")
      else if n.label == "" then some ("node " ++ n.id ++ " has empty label")
      else none
  let edgeErrors :=
    g.edges.filterMap fun e =>
      if !ids.contains e.src then
        some ("edge " ++ e.label ++ " has unknown src: " ++ e.src)
      else if !ids.contains e.dst then
        some ("edge " ++ e.label ++ " has unknown dst: " ++ e.dst)
      else if e.label == "" then
        some ("edge " ++ e.src ++ " -> " ++ e.dst ++ " has empty label")
      else
        none
  duplicateIdErrors ++ nodeErrors ++ edgeErrors

def aggregateGraphValidationReport (g : AggregateGraphData) : String :=
  match validateAggregateGraph g with
  | [] => "ok: aggregate graph data is well-formed\n"
  | errors => "invalid aggregate graph data\n" ++ joinWithNewline errors ++ "\n"

end LeanFM
