import Lean.Data.Json
import LeanFM.Session.Calls
import LeanFM.Session.Types

/-!
# A role's HTTP interface as OpenAPI (clause selfhost.session.openapi)

The requests a role receives, with their routes and the responses the protocol allows, are that
role's HTTP interface. `Global.openApi` writes them as an OpenAPI 3.1 document: one operation per
route (`route "POST /orders"` gives method `post` on path `/orders`), the request's label as its
`operationId` and request body, and each response under its status (or `default` when the
protocol gives none) with the response's label as its body. Each body's schema is its message
type (selfhost.session.types): the structure's fields, with the protobuf JSON mapping's types, the
non-`Option` fields required and no others allowed; a label with no structure is an empty object.

One route may carry several messages, as an endpoint whose request takes several shapes (OAuth's
callback with a code or with an error): they share one operation, its operationId joins their
labels, and a body that may be either is `oneOf` their schemas. As HTTP is normally used, a request
without a body (GET, DELETE) carries its message's single fields as query parameters, required
unless `Option` or missing from one of the messages, and a redirect (a 3xx response) carries its
message in the `Location` URL rather than in a body.

Negative requirements: a request without a route is not guessed into the document (it is listed
as unrouted); a route that is not a method and a path starting with `/` is an error; nothing but labels, routes and statuses from the
protocol reaches the document, and only as JSON strings; no schema admits a field its message type
does not declare.
-/

namespace LeanFM.Session
open Lean

namespace OpenApi

def methods : List String := ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

/-- `"POST /orders"` as (`post`, `/orders`). -/
def splitRoute (route : String) : Except String (String × String) :=
  match route.splitOn " " |>.filter (· != "") with
  | [m, p] =>
    let m := m.toLower
    if !methods.contains m then throw s!"route \"{route}\": {m} is not an HTTP method"
    else if !p.startsWith "/" then throw s!"route \"{route}\": the path must start with /"
    else pure (m, p)
  | _ => throw s!"route \"{route}\" is not a method and a path, such as \"POST /orders\""

/-- Every call, nested ones included. -/
partial def flatten {R : Type} (cs : List (Call R)) : List (Call R) :=
  cs.flatMap fun c => c :: flatten c.nested

def ref (label : String) : Json :=
  Json.mkObj [("$ref", Json.str s!"#/components/schemas/{label}")]

def jsonBody (label : String) : Json :=
  Json.mkObj [("content", Json.mkObj [("application/json", Json.mkObj [("schema", ref label)])])]

end OpenApi

open OpenApi in
/-- The OpenAPI 3.1 document of the requests `role` receives, and the requests it receives
without a route. -/
def Global.openApi (g : Global String) (title role : String) (types : Types.Env := []) : Except String (Json × List String) := do
  let calls := (flatten g.calls).filter (·.request.dst == role)
  let unrouted := (calls.filter (·.request.route.isNone)).map fun c => s!"{c.request.label} from {c.request.src}"
  -- one route may carry several messages (an endpoint whose request takes several shapes, such as
  -- OAuth's callback with a code or with an error): they share one operation
  let mut ops : List (String × String × List (Call String)) := []  -- path, method, calls
  for c in calls do
    if let some route := c.request.route then
      let (m, p) ← splitRoute route
      match ops.find? (fun (p', m', _) => p' == p && m' == m) with
      | some (_, _, others) =>
        if !others.any (·.request.label == c.request.label) then
          ops := ops.map fun (p', m', cs) => if p' == p && m' == m then (p', m', cs ++ [c]) else (p', m', cs)
      | none => ops := ops ++ [(p, m, [c])]
  let paths := (ops.map (·.1)).eraseDups.map fun p =>
    let here := ops.filter (·.1 == p)
    (p, Json.mkObj (here.map fun (_, m, cs) =>
      let reqs := cs.map (·.request.label)
      let rs := (cs.flatMap (·.responses)).foldl (fun acc r =>
        let key := (r.status.map toString).getD "default"
        match acc.find? (·.1 == key) with
        | some (_, ls) => if ls.contains r.label then acc else acc.map fun (k, l) => if k == key then (k, l ++ [r.label]) else (k, l)
        | none => acc ++ [(key, [r.label])]) []
      let body (ls : List String) : Json := match ls with
        | [l] => jsonBody l
        | ls => Json.mkObj [("content", Json.mkObj [("application/json", Json.mkObj [("schema",
            Json.mkObj [("oneOf", Json.arr (ls.map ref).toArray)])])])]
      -- a redirect carries its message in the Location URL's query, not in a body, as browsers follow it
      let fieldList (ls : List String) : String :=
        ", ".intercalate ((ls.flatMap fun l => (Types.fieldsOf types l).map (·.name)).eraseDups)
      let responses := if rs.isEmpty then [("default", Json.mkObj [("description", Json.str "the protocol gives no response")])]
        else rs.map fun (key, ls) =>
          if key.startsWith "3" then
            let carried := fieldList ls
            (key, Json.mkObj [("description", Json.str (" or ".intercalate ls ++
                (if carried.isEmpty then "" else s!": the Location URL carries {carried} as query parameters"))),
              ("headers", Json.mkObj [("Location", Json.mkObj [("required", Json.bool true),
                ("schema", Json.mkObj [("type", "string"), ("format", "uri")])])])])
          else (key, (body ls).setObjVal! "description" (Json.str (" or ".intercalate ls)))
      -- a request without a body carries its message's single fields as query parameters
      let params : List Json := if ["post", "put", "patch"].contains m then [] else
        let names := (reqs.flatMap fun l => (Types.fieldsOf types l).map (·.name)).eraseDups
        names.filterMap fun n =>
          let tys := reqs.filterMap fun l => ((Types.fieldsOf types l).find? (·.name == n)).map (·.ty)
          let required := reqs.all fun l => (Types.fieldsOf types l).any fun f => f.name == n &&
            (match f.ty with | .opt _ => false | _ => true)
          match tys.head? with
          | some t@(.nat) | some t@(.int) | some t@(.str) | some t@(.bool) =>
            some (Json.mkObj [("name", Json.str n), ("in", "query"), ("required", Json.bool required), ("schema", t.schema)])
          | some (.opt t) =>
            some (Json.mkObj [("name", Json.str n), ("in", "query"), ("required", Json.bool false), ("schema", t.schema)])
          | _ => none
      let srcs := (cs.map (·.request.src)).eraseDups
      let op := [("operationId", Json.str (String.join reqs)),
        ("summary", Json.str s!"{" or ".intercalate reqs} from {" or ".intercalate srcs}"),
        ("responses", Json.mkObj responses)] ++
        (if params.isEmpty then [] else [("parameters", Json.arr params.toArray)]) ++
        (if ["post", "put", "patch"].contains m then [("requestBody", body reqs)] else [])
      (m, Json.mkObj op)))
  let labels := (ops.flatMap fun (_, _, cs) => cs.flatMap fun c => c.request.label :: c.responses.map (·.label)).eraseDups
  let schemas := (← Types.complete types labels (onlyUsed := true)).map fun m => (m.name, m.schema)
  let doc := Json.mkObj [("openapi", "3.1.0"),
    ("info", Json.mkObj [("title", Json.str s!"{title}: {role}"), ("version", "0.1.0"),
      ("description", Json.str s!"The requests {role} receives in protocol {title}, generated by LeanFM from the session type.")]),
    ("paths", Json.mkObj paths), ("components", Json.mkObj [("schemas", Json.mkObj schemas)])]
  return (doc, unrouted)

end LeanFM.Session
