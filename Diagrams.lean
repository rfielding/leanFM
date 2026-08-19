import LeanFM

def writeDiagram (name dot : String) : IO Unit := do
  IO.FS.createDirAll "diagrams"
  let dotPath := s!"diagrams/{name}.dot"
  let svgPath := s!"diagrams/{name}.svg"
  let pngPath := s!"diagrams/{name}.png"
  IO.FS.writeFile dotPath dot
  let svgChild ← IO.Process.output
    { cmd := "dot"
    , args := #["-Tsvg", dotPath, "-o", svgPath]
    }
  let pngChild ← IO.Process.output
    { cmd := "dot"
    , args := #["-Tpng", dotPath, "-o", pngPath]
    }
  if svgChild.exitCode = 0 && pngChild.exitCode = 0 then
    IO.println s!"wrote {svgPath}"
    IO.println s!"wrote {pngPath}"
  else
    throw <| IO.userError s!"dot failed for {dotPath}: {svgChild.stderr}{pngChild.stderr}"

def main : IO Unit := do
  writeDiagram "auth" LeanFM.authGraphDot
  writeDiagram "worker" LeanFM.graphDot
  writeDiagram "assembled" LeanFM.assembledGraphDot
