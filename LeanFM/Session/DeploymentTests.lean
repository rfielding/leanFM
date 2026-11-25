import LeanFM.SessionTools

/-!
Tests of `deployment` blocks and `session_deployment` (selfhost.session.deployment): the book's Orders
deployment and the Telemetry example are placed with the interfaces and conditions the topology
gives; every forbidden deployment is refused with its reason; a deployment changes nothing the
protocol tools say about the protocol; the view escapes what it draws.
-/

namespace LeanFM.Session.DeploymentTests
open Lean LeanFM.SessionTools

def orders : String := include_str "../../examples/orders/Implementation.leanfm"
def telemetry : String := include_str "../../examples/deployment/Telemetry.leanfm"

def run (text : String) (extra : List (String × Json) := []) : Json :=
  match deployment (Json.mkObj ([("lean", Json.str text)] ++ extra)) with
  | .ok j => j
  | .error e => Json.mkObj [("error", Json.str e)]
def str (j : Json) (k : String) : String := (j.getObjValAs? String k).toOption.getD ""
def arr (j : Json) (k : String) : List Json := ((j.getObjValD k).getArr?).toOption.getD #[] |>.toList
def linkOf (j : Json) (s d : String) : Json :=
  ((arr j "links").find? fun l => str l "from" == s && str l "to" == d).getD Json.null
def conds (l : Json) : List String := (arr l "conditions").filterMap (·.getStr?.toOption)
def issues (j : Json) : List String := (arr j "issues").map (str · "issue")
def occurs (s pat : String) : Nat := (s.splitOn pat).length - 1

/-- Refused, by session_deployment or by the reader, with a reason containing `needle`. -/
def refusedWith (text needle : String) : Bool :=
  let j := run text
  (str j "verdict" == "refused" && (issues j).any (·.contains needle)) || (str j "error").contains needle

-- the book's Orders deployment
def o := run orders
#guard str o "verdict" == "placed"
#guard (arr o "placements").map (str · "role") == ["Client", "Api", "Db", "Bank"]
#guard str (linkOf o "Client" "Api") "via" == "us.Api.ingress.https"
#guard (conds (linkOf o "Client" "Api")).contains "hostile"
#guard str (linkOf o "Api" "Bank") "via" == "eu.Bank.peering.api"
#guard (conds (linkOf o "Api" "Bank")).contains "partition"
#guard str (linkOf o "Api" "Db") "via" == "us.Db.local.sql" && conds (linkOf o "Api" "Db") == []
-- replies travel back over the link they answer: the client needs no interface, the database's
-- replies are not hostile, and the bank's carry the partition of the call they answer
#guard str (linkOf o "Api" "Client") "via" == "us.Api.ingress.https" && (str (linkOf o "Api" "Client") "note").contains "replies"
#guard str (linkOf o "Db" "Api") "via" == "us.Db.local.sql" && conds (linkOf o "Db" "Api") == []
#guard str (linkOf o "Bank" "Api") "via" == "eu.Bank.peering.api" && (conds (linkOf o "Bank" "Api")).contains "partition" &&
       !(conds (linkOf o "Bank" "Api")).contains "hostile"
-- a call to a role with no interfaces is unrestricted, and says so
def pushed := run "protocol P (A, B) { Push from A to B; }\ndeployment D of P { outside { B; } island us { A; } }"
#guard str pushed "verdict" == "placed" && (str (linkOf pushed "A" "B") "note").contains "unrestricted"
-- one box per role, one arrow per link
#guard occurs (str o "svg") "class=\"role\"" == 4
#guard occurs (str o "svg") "class=\"link" == (arr o "links").length
#guard occurs (str o "svg") "link refused" == 0

-- a deployment adds no step: the protocol reads the same with and without it
def withoutDeployment : String := (orders.splitOn "\n-- Where ShopImpl runs").headD orders
#guard str ((check (Json.mkObj [("lean", Json.str orders)])).toOption.getD Json.null) "reading" ==
       str ((check (Json.mkObj [("lean", Json.str withoutDeployment)])).toOption.getD Json.null) "reading"
#guard str ((check (Json.mkObj [("lean", Json.str orders)])).toOption.getD Json.null) "reading" != ""

-- Telemetry: a declared kind adds its condition, a sharded group per-key order, islands partition
def t := run telemetry
#guard str t "verdict" == "placed"
#guard ["deadline exceeded", "per-key order", "partition"].all (conds (linkOf t "Gateway" "Store")).contains
#guard str (linkOf t "Gateway" "Alerts") "via" == "core.Alerts.peering.page"

-- refused
def base := "protocol Shop (Client, Api, Bank) {\n  o: Order from Client to Api;\n  c: Charge from Api to Bank cause o;\n  Charged from Bank to Api cause c;\n  Done from Api to Client cause o;\n  Peek from Client to Bank;\n}\n"
#guard refusedWith (base ++ "deployment A of Shop { outside { Client; } island us { Api; } island eu { Bank { internal admin : api; } } }")
  "Client cannot send Peek to Bank: eu.Bank.internal.admin is internal, reachable only from island eu"
#guard refusedWith (base ++ "deployment A of Shop { outside { Client; } island us { machine m { Api; Bank { local x : call; } } } }")
  "is local, reachable only from machine m"
#guard refusedWith (base ++ "deployment A of Shop { outside { Client; } island us { Api; Bank { peering x : call; } } }")
  "is peering, not reachable from outside"
#guard refusedWith (base ++ "deployment A of Shop { outside { Client; } island us { Api; } }") "Bank is a role of Shop and is not placed"
#guard refusedWith (base ++ "deployment A of Shop { outside { Client; Client; } island us { Api; Bank; } }") "Client is placed 2 times"
#guard refusedWith (base ++ "deployment A of Shop { outside { Client; } island us { Api; Bank; Robot; } }") "Robot is not a role of Shop"
#guard refusedWith (base ++ "deployment A of Shop { outside { Client; } island us { Api { ingress h : soap; } Bank; } }") "kind soap is not built in"
#guard refusedWith (base ++ "deployment A of Shop { kind http refines api; outside { Client; } island us { Api; Bank; } }") "kind http is already a kind"
#guard refusedWith (base ++ "deployment A of Shop { outside { Client; } island us { Api { ingress h : http; local h : call; } Bank; } }") "Api has two interfaces named h"
#guard refusedWith (base ++ "deployment A of Shop { outside { Client; } island us { machine m { island x { Api; Bank; } } } }") "island x is inside another group"
#guard refusedWith (base ++ "deployment A of Shop { outside { Client; } machine m { Api; Bank; } }") "machine m is at the top of the tree"
#guard refusedWith (base ++ "deployment A of Shop { Client; }") "Client is at the top of the tree"
#guard refusedWith (base ++ "deployment A of Nope { outside { Client; } }") "no protocol Nope is defined before it"
#guard refusedWith (base ++ "deployment A of Shop { outside { Client; } island us { Api; Bank; } }\ndeployment A of Shop { outside { Client; } island us { Api; Bank; } }") "deployment A is defined twice"
#guard refusedWith base "declares no deployment"
-- a refused link is drawn dashed
def twoRefused := run (base ++ "deployment A of Shop { outside { Client; } island us { Api; } island eu { Bank { internal admin : api; } } }")
-- Peek and Charge are refused, and Charged, the reply to Charge, with them; only the calls are issues
#guard (twoRefused.getObjValAs? Nat "refused").toOption == some 3 && occurs (str twoRefused "svg") "link refused" == 3
#guard (issues twoRefused).length == 2
-- every name and condition drawn is escaped
def evil := run (base ++ "deployment A of Shop { kind k refines api adds \"<script>x</script>\"; outside { Client; } island us { Api { ingress h : k; } Bank; } }")
#guard str evil "verdict" == "placed" && !(str evil "svg").contains "<script>" && (str evil "svg").contains "&lt;script&gt;"
-- a named deployment, and the light theme
#guard str (run (base ++ "deployment A of Shop { outside { Client; } island us { Api; Bank; } }\ndeployment B of Shop { outside { Client; Api; Bank; } }") [("deployment", Json.str "A")]) "name" == "A"
#guard (str (run orders [("theme", Json.str "light")]) "svg").contains DiagramTheme.light.bg

end LeanFM.Session.DeploymentTests
