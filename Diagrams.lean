import LeanFM

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
