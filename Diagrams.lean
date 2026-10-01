import LeanFM

def aggregateDot (name : String) (graph : LeanFM.AggregateGraphData) : String :=
  LeanFM.joinWithNewline <|
    [ "digraph " ++ name ++ " {"
    , "  rankdir=LR;"
    , "  graph [bgcolor=\"#111111\"];"
    , "  node [shape=box,style=\"rounded,filled\",fillcolor=\"#1f2937\",fontcolor=white,color=\"#60a5fa\"];"
    , "  edge [fontcolor=white,color=\"#94a3b8\"];"
    ] ++
    graph.nodes.map (fun n => "  " ++ LeanFM.jsonString n.id ++ " [label=" ++ LeanFM.jsonString n.label ++ "];") ++
    graph.edges.map (fun e => "  " ++ LeanFM.jsonString e.src ++ " -> " ++ LeanFM.jsonString e.dst ++ " [label=" ++ LeanFM.jsonString e.label ++ "];") ++
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
