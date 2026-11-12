import Lean.Data.Json
import Std.Data.HashMap

/-!
# The cost of every check, for /metrics (selfhost.mcp.metrics)

Each tool call the MCP endpoint answers is recorded: how long it took, how large a model it
generated, whether it was cut off at a bound, and how many secrets it decided. `Stats` is pure;
the process keeps one in `checkStats`, and `/metrics` renders it in the Prometheus text format.

Label values come from fixed sets only. The tool label is a listed tool's name or `other`; the
verdict label is one of `verdicts` or `other`, and `rejected` for a call that failed. Nothing
else from a call's arguments or answer reaches a label, so no protocol text, term, secret name,
formula or error message can appear in a metric.
-/

namespace LeanFM.CheckMetrics
open Lean

/-- The verdict words a label may carry; any other verdict is `other`. -/
def verdicts : List String :=
  ["proved", "disproved", "resource-limit", "unknown", "unsupported", "met", "violated", "undecided", "open",
   "ok", "issues", "conforms", "violates", "clean", "findings", "generated", "answered", "compatible",
   "incompatible", "running", "finished", "stuck", "kept", "leaked", "rejected"]

structure Hist where
  bounds : Array Float
  counts : Array Nat
  sum : Float := 0
  count : Nat := 0
  deriving Inhabited

def Hist.empty (bounds : Array Float) : Hist := { bounds, counts := Array.replicate bounds.size 0 }

/-- Add one observation: every bucket whose bound is at least `v` counts it, so buckets are cumulative. -/
def Hist.observe (h : Hist) (v : Float) : Hist :=
  { h with counts := (h.bounds.zip h.counts).map (fun (b, c) => if v ≤ b then c + 1 else c),
           sum := h.sum + v, count := h.count + 1 }

def secondsBuckets : Array Float := #[0.001, 0.01, 0.1, 1, 10, 60]
def sizeBuckets : Array Float := #[10, 100, 1000, 10000, 100000, 1000000]
def secretBuckets : Array Float := #[1, 2, 4, 8, 16]

structure Series where
  calls : Nat := 0
  duration : Hist := Hist.empty secondsBuckets
  states : Hist := Hist.empty sizeBuckets
  transitions : Hist := Hist.empty sizeBuckets
  deriving Inhabited

structure Stats where
  /-- per (tool, verdict) -/
  series : Std.HashMap (String × String) Series := {}
  /-- per tool: answers cut off at a bound -/
  boundHits : Std.HashMap String Nat := {}
  /-- per tool: secrets decided per call -/
  secrets : Std.HashMap String Hist := {}
  deriving Inhabited

def toolLabel (listed : List String) (tool : String) : String := if listed.contains tool then tool else "other"

def verdictLabel (result : Except String Json) : String :=
  match result with
  | .error _ => "rejected"
  | .ok j =>
    let v := ((j.getObjVal? "structuredContent").toOption.getD j).getObjValAs? String "verdict" |>.toOption
    match v with
    | some w => if verdicts.contains w then w else "other"
    | none => "other"

/-- A whole number field of the answer (or of its structuredContent), if it has one. -/
def natField (result : Except String Json) (k : String) : Option Nat :=
  match result with
  | .error _ => none
  | .ok j => ((j.getObjVal? "structuredContent").toOption.getD j).getObjValAs? Nat k |>.toOption

def secretsDecided (result : Except String Json) : Option Nat :=
  match result with
  | .error _ => none
  | .ok j => match ((j.getObjVal? "structuredContent").toOption.getD j).getObjVal? "secrets" with
    | .ok (.arr a) => some a.size
    | _ => none

/-- Record one call. Only the tool name and the verdict word become labels. -/
def Stats.record (s : Stats) (listed : List String) (tool : String) (result : Except String Json) (nanos : Nat) : Stats :=
  let t := toolLabel listed tool
  let v := verdictLabel result
  let ser := (s.series.get? (t, v)).getD {}
  let ser := { ser with calls := ser.calls + 1, duration := ser.duration.observe (nanos.toFloat / 1e9) }
  let ser := match natField result "states" with | some n => { ser with states := ser.states.observe n.toFloat } | none => ser
  let ser := match natField result "transitions" with | some n => { ser with transitions := ser.transitions.observe n.toFloat } | none => ser
  let s := { s with series := s.series.insert (t, v) ser }
  let s := if v == "resource-limit" then { s with boundHits := s.boundHits.insert t ((s.boundHits.get? t).getD 0 + 1) } else s
  match secretsDecided result with
  | some n => { s with secrets := s.secrets.insert t (((s.secrets.get? t).getD (Hist.empty secretBuckets)).observe n.toFloat) }
  | none => s

/-- A number as Prometheus reads it: whole numbers without a point, others without trailing zeros. -/
def fmt (x : Float) : String :=
  if x == x.floor && x.abs < 1e15 then toString x.toUInt64
  else
    let s := toString x
    if s.contains 'e' || !s.contains '.' then s
    else
      let t := (s.toList.reverse.dropWhile (· == '0')).reverse
      String.ofList (if t.getLast? == some '.' then t.dropLast else t)

def labels (kvs : List (String × String)) : String :=
  "{" ++ ",".intercalate (kvs.map fun (k, v) => s!"{k}=\"{v}\"") ++ "}"

def Hist.lines (name : String) (ls : List (String × String)) (h : Hist) : List String :=
  (h.bounds.zip h.counts).toList.map (fun (b, c) => s!"{name}_bucket{labels (ls ++ [("le", fmt b)])} {c}") ++
  [s!"{name}_bucket{labels (ls ++ [("le", "+Inf")])} {h.count}",
   s!"{name}_sum{labels ls} {fmt h.sum}",
   s!"{name}_count{labels ls} {h.count}"]

/-- The Prometheus text exposition of the recorded calls, sorted so the output is stable. -/
def Stats.render (s : Stats) : String :=
  let ser := s.series.toList.mergeSort (fun a b => a.1.1 < b.1.1 || (a.1.1 == b.1.1 && a.1.2 ≤ b.1.2))
  let ls := fun ((t, v) : String × String) => [("tool", t), ("verdict", v)]
  let block := fun (name help kind : String) (body : List String) =>
    [s!"# HELP {name} {help}", s!"# TYPE {name} {kind}"] ++ body
  let hits := s.boundHits.toList.mergeSort (fun a b => a.1 ≤ b.1)
  let secs := s.secrets.toList.mergeSort (fun a b => a.1 ≤ b.1)
  "\n".intercalate (
    block "leanfm_check_calls_total" "Tool calls answered by the MCP endpoint since the service started." "counter"
      (ser.map fun (k, x) => s!"leanfm_check_calls_total{labels (ls k)} {x.calls}") ++
    block "leanfm_check_duration_seconds" "Wall-clock time per tool call." "histogram"
      (ser.flatMap fun (k, x) => x.duration.lines "leanfm_check_duration_seconds" (ls k)) ++
    block "leanfm_check_states_explored" "States in the model a check generated, when it reports them." "histogram"
      (ser.flatMap fun (k, x) => if x.states.count == 0 then [] else x.states.lines "leanfm_check_states_explored" (ls k)) ++
    block "leanfm_check_transitions_explored" "Transitions in the model a check generated, when it reports them." "histogram"
      (ser.flatMap fun (k, x) => if x.transitions.count == 0 then [] else x.transitions.lines "leanfm_check_transitions_explored" (ls k)) ++
    block "leanfm_check_bound_hits_total" "Answers cut off at a bound (resource-limit)." "counter"
      (hits.map fun (t, n) => s!"leanfm_check_bound_hits_total{labels [("tool", t), ("bound", "model-size")]} {n}") ++
    block "leanfm_check_secrets_checked" "Secrets a check_protocol call decided." "histogram"
      (secs.flatMap fun (t, h) => h.lines "leanfm_check_secrets_checked" [("tool", t)])) ++ "\n"

/-- The process's recorded calls. -/
initialize checkStats : IO.Ref Stats ← IO.mkRef {}

end LeanFM.CheckMetrics
