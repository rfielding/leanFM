import LeanFM.UiModel

namespace LeanFM

inductive GeneratedArtifact where
  | aggregateGraph : String -> String -> AggregateGraphData -> GeneratedArtifact
  | markdown : String -> String -> String -> GeneratedArtifact
deriving Repr

def GeneratedArtifact.id : GeneratedArtifact -> String
  | .aggregateGraph id _ _ => id
  | .markdown id _ _ => id

def GeneratedArtifact.title : GeneratedArtifact -> String
  | .aggregateGraph _ title _ => title
  | .markdown _ title _ => title

def validateGeneratedArtifact : GeneratedArtifact -> List String
  | .aggregateGraph id title data =>
      (if id == "" then ["artifact has empty id"] else []) ++
      (if title == "" then ["artifact " ++ id ++ " has empty title"] else []) ++
      (validateAggregateGraph data).map (fun msg => "artifact " ++ id ++ ": " ++ msg)
  | .markdown id title body =>
      (if id == "" then ["artifact has empty id"] else []) ++
      (if title == "" then ["artifact " ++ id ++ " has empty title"] else []) ++
      (if body == "" then ["artifact " ++ id ++ " has empty markdown body"] else [])

def validateGeneratedArtifacts (artifacts : List GeneratedArtifact) : List String :=
  artifacts.foldr (fun artifact acc => validateGeneratedArtifact artifact ++ acc) []

def generatedArtifactValidationReport (artifacts : List GeneratedArtifact) : String :=
  match validateGeneratedArtifacts artifacts with
  | [] => "ok: all generated artifacts are well-formed typed Lean values\n"
  | errors => "invalid generated artifacts\n" ++ joinWithNewline errors ++ "\n"

end LeanFM
