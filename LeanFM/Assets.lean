namespace LeanFM

def joinLines : List String -> String
  | [] => ""
  | [x] => x
  | x :: xs => x ++ "\n" ++ joinLines xs

inductive AssetKind where
  | javascript
  | markdown
  | json
  | text
deriving DecidableEq, Repr

def AssetKind.mediaType : AssetKind -> String
  | .javascript => "application/javascript"
  | .markdown => "text/markdown"
  | .json => "application/json"
  | .text => "text/plain"

def AssetKind.label : AssetKind -> String
  | .javascript => "javascript"
  | .markdown => "markdown"
  | .json => "json"
  | .text => "text"

structure GeneratedAsset where
  name : String
  kind : AssetKind
  mediaType : String
  body : String
  requires : List String := []
deriving Repr

structure AssetDiagnostic where
  asset : String
  message : String
  fix : String
deriving Repr

structure AssetValidation where
  ok : Bool
  diagnostics : List AssetDiagnostic
deriving Repr

def validateAsset (asset : GeneratedAsset) : List AssetDiagnostic :=
  let base :=
    (if asset.name == "" then
      [{ asset := asset.name, message := "asset name is empty", fix := "provide a stable generated asset name" }]
    else []) ++
    (if asset.body == "" then
      [{ asset := asset.name, message := "asset body is empty", fix := "generate non-empty asset content" }]
    else []) ++
    (if asset.mediaType != asset.kind.mediaType then
      [{ asset := asset.name
       , message := "media type does not match declared kind " ++ asset.kind.label
       , fix := "set mediaType to " ++ asset.kind.mediaType }]
    else [])
  let requiredDiagnostics :=
    asset.requires.filterMap fun marker =>
      if asset.body.contains marker then
        none
      else
        some { asset := asset.name
             , message := "missing required marker: " ++ marker
             , fix := "include the required DOM hook, export, or model marker in the generated asset" }
  let scriptDiagnostics :=
    if asset.kind == .javascript && asset.body.contains "</script>" then
      [{ asset := asset.name
       , message := "javascript contains an inline script terminator"
       , fix := "escape or remove </script> before embedding in HTML" }]
    else []
  base ++ requiredDiagnostics ++ scriptDiagnostics

def validateAssets (assets : List GeneratedAsset) : AssetValidation :=
  let diagnostics := assets.foldr (fun asset acc => validateAsset asset ++ acc) []
  { ok := diagnostics.isEmpty, diagnostics }

def diagnosticLine (d : AssetDiagnostic) : String :=
  "- " ++ d.asset ++ ": " ++ d.message ++ "\n  fix: " ++ d.fix

def assetValidationReport (validation : AssetValidation) : String :=
  if validation.ok then
    "ok: all generated assets fit their declared contracts\n"
  else
    "invalid generated assets\n" ++ joinLines (validation.diagnostics.map diagnosticLine) ++ "\n"

end LeanFM
