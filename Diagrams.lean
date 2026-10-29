import LeanFM

def writeDiagram (name dot : String) : IO Unit := do
  IO.FS.createDirAll "diagrams"
  let dotPath := s!"diagrams/{name}.dot"
  IO.FS.writeFile dotPath dot
  IO.println s!"wrote {dotPath}"

def offlineSvgGallery : String :=
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>LeanFM SVG artifacts</title>" ++
  "<meta name=\"color-scheme\" content=\"dark only\"><style>html,body{background:#111;color:#f8f8f8;font-family:system-ui,sans-serif}body{margin:2rem}figure{background:#090909;border:1px solid #444;padding:1rem;margin:1rem 0}img{display:block;max-width:100%;height:auto;margin:auto}a{color:#93c5fd}figcaption{margin-top:.5rem;color:#cbd5e1}</style></head><body>" ++
  "<h1>LeanFM generated visual artifacts</h1><p>Each image is derived from typed requirements and its declared event reducer.</p>" ++
  String.join (LeanFM.svgArtifactNames.map fun name =>
    "<figure id=\"" ++ name ++ "\"><a href=\"" ++ name ++ ".svg\"><img src=\"" ++ name ++ ".svg\" alt=\"" ++ name ++ "\"></a><figcaption>" ++ name ++ " — standalone SVG</figcaption></figure>") ++
  "</body></html>"

def main : IO Unit := do
  writeDiagram "auth" LeanFM.authGraphDot
  writeDiagram "worker" LeanFM.groupedGraphDot
  writeDiagram "get_docs" LeanFM.getDocsGraphDot
  writeDiagram "post_review" LeanFM.postReviewGraphDot
  writeDiagram "tasks" LeanFM.taskGraphDot
  writeDiagram "assembled" LeanFM.assembledGraphDot
  for name in LeanFM.svgArtifactNames do
    match LeanFM.renderSvg name with
    | some body =>
        let path := s!"diagrams/{name}.svg"
        IO.FS.writeFile path body
        IO.println s!"wrote {path}"
    | none => pure ()
  IO.FS.writeFile "diagrams/index.html" offlineSvgGallery
  IO.println "wrote diagrams/index.html"
  IO.FS.writeFile "diagrams/theorems.html" LeanFM.theoremRenderPage
  IO.println "wrote diagrams/theorems.html"
