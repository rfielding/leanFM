import LeanFM

private def firstNodePerTask (seen : List String) : List LeanFM.AggregateNode -> List String
  | [] => []
  | node :: rest =>
      if seen.contains node.task then
        firstNodePerTask seen rest
      else
        node.id :: firstNodePerTask (node.task :: seen) rest

private def terminalNodes (nodes : List LeanFM.AggregateNode) : List String :=
  (nodes.filter (fun node => node.terminal)).map (fun node => node.id)

private def stackComponents : List String -> List String -> List String
  | terminal :: terminals, _ :: nextRoot :: roots =>
      ("  " ++ LeanFM.jsonString terminal ++ " -> " ++ LeanFM.jsonString nextRoot ++
        " [style=invis,weight=100,minlen=2];") ::
        stackComponents terminals (nextRoot :: roots)
  | _, _ => []

def aggregateDot (name : String) (graph : LeanFM.AggregateGraphData) : String :=
  LeanFM.joinWithNewline <|
    [ "digraph " ++ name ++ " {"
    , "  rankdir=TB;"
    , "  graph [bgcolor=\"#111111\"];"
    , "  node [shape=box,style=\"rounded,filled\",fillcolor=\"#1f2937\",fontcolor=white,color=\"#60a5fa\"];"
    , "  edge [fontcolor=white,color=\"#94a3b8\"];"
    ] ++
    graph.nodes.map (fun n => "  " ++ LeanFM.jsonString n.id ++ " [label=" ++ LeanFM.jsonString n.label ++ "];") ++
    graph.edges.map (fun e => "  " ++ LeanFM.jsonString e.src ++ " -> " ++ LeanFM.jsonString e.dst ++ " [label=" ++ LeanFM.jsonString e.label ++ "];") ++
    stackComponents (terminalNodes graph.nodes) (firstNodePerTask [] graph.nodes) ++
    [ "}" ]

def taskGraph (task : String) : LeanFM.AggregateGraphData :=
  let all := LeanFM.requirementAggregateGraphData LeanFM.PaxosKV.Requirements.spec
  { nodes := all.nodes.filter (fun n => n.task == task)
  , edges := all.edges.filter (fun e => LeanFM.stringContains e.src (task ++ ".")) }

def writeDiagram (name dot : String) : IO Unit := do
  IO.FS.createDirAll "diagrams"
  let dotPath := s!"diagrams/{name}.dot"
  IO.FS.writeFile dotPath dot
  IO.println s!"wrote {dotPath}"

def eventFieldLines (fields : List (String × String)) : List String :=
  fields.map fun field => field.1 ++ " = " ++ field.2

def detailedEventLabel (event : LeanFM.PaxosKV.Requirements.ScenarioEvent) : String :=
  LeanFM.joinWithNewline <|
    [event.id ++ ": " ++ event.message, event.src ++ " -> " ++ event.dst] ++
    eventFieldLines event.fieldValues

def detailedMessageOrderDot (name : String)
    (events : List LeanFM.PaxosKV.Requirements.ScenarioEvent) : String :=
  LeanFM.joinWithNewline <|
    [ "digraph " ++ name ++ " {"
    , "  rankdir=BT;"
    , "  graph [bgcolor=\"#111111\",label=\"arrows point to immediate prior events\",fontcolor=white];"
    , "  node [shape=box,style=\"rounded,filled\",fillcolor=\"#1f2937\",fontcolor=white,color=\"#60a5fa\",fontname=\"monospace\"];"
    , "  edge [fontcolor=white,color=\"#94a3b8\"];"
    ] ++
    events.map (fun event => "  " ++ LeanFM.jsonString event.id ++ " [label=" ++ LeanFM.jsonString (detailedEventLabel event) ++ "];") ++
    LeanFM.concatLists (events.map fun event => event.priorIds.map fun priorId =>
      "  " ++ LeanFM.jsonString event.id ++ " -> " ++ LeanFM.jsonString priorId ++ ";") ++
    [ "}" ]

def main : IO Unit := do
  writeDiagram "auth" LeanFM.authGraphDot
  writeDiagram "worker" LeanFM.groupedGraphDot
  writeDiagram "get_docs" LeanFM.getDocsGraphDot
  writeDiagram "post_review" LeanFM.postReviewGraphDot
  writeDiagram "tasks" LeanFM.taskGraphDot
  writeDiagram "assembled" LeanFM.assembledGraphDot
  writeDiagram "paxos-kv" <| aggregateDot "paxos_kv" <|
    LeanFM.requirementAggregateGraphData LeanFM.PaxosKV.Requirements.spec
  writeDiagram "paxos-quorum-write" <| aggregateDot "paxos_quorum_write" <| taskGraph "quorum_write"
  writeDiagram "paxos-linearizable-list" <| aggregateDot "paxos_linearizable_list" <| taskGraph "linearizable_list"
  writeDiagram "paxos-recovery" <| aggregateDot "paxos_recovery" <| taskGraph "recover_replica"
  writeDiagram "paxos-quorum-write-messages" <|
    detailedMessageOrderDot "paxos_quorum_write_messages" LeanFM.PaxosKV.Requirements.quorumWriteExample
