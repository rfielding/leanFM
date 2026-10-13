import LeanFM.ReliabilityDiagram

/- Book example, not an accepted deployment specification. The renderer derives
   actor IDs and gate labels from these typed populations and dependency gates. -/
namespace RuntimeDiagram
open LeanFM

def pool (actor idPrefix : String) (count : Nat) : ActorPopulation :=
  { actorSpec := actor, instancePrefix := idPrefix, count, routing := .roundRobin }
def pools : List ActorPopulation :=
  [pool "Ingress" "ingress-" 2, pool "Web" "web-" 3, pool "Router" "router-" 2]
def shards : List ActorPopulation := (List.range 8).map fun i =>
  { actorSpec := "Shard" ++ toString i, instancePrefix := "s" ++ toString i ++ "-r",
    count := 3, routing := .shardHash "document_partition" }
def gates : List ReliabilityDependencyGate :=
  (pools.map fun p => ({ id := p.actorSpec, members := p.instanceIds, requiredCount := 1, affectedTasks := ["targeted_document_write"] } : ReliabilityDependencyGate)) ++
  (shards.map fun p => ({ id := p.actorSpec, members := p.instanceIds, requiredCount := 2, affectedTasks := ["targeted_document_write"] } : ReliabilityDependencyGate))
def output : DesiredOutput :=
  { id := "runtime.actor_network", prompt := "Start the reliability/Kubernetes section with actors highlighting series, parallel, thresholds and sharding.",
    question := "Which actor pools and selected shard gate are required by one targeted write?",
    kind := .interactionDiagram, eventSource := "RuntimeReliabilityDiagram.lean typed illustrative populations and dependency gates; no empirical events",
    reducer := "project pool member IDs and gate thresholds into a topology, showing shared tiers in series and one selected shard dependency",
    unit := "actors and eligibility gates; illustrative targeted-write topology, excludes metadata and infrastructure detail" }

example : shards.length = 8 := by native_decide
example : (shards.flatMap ActorPopulation.instanceIds).length = 24 := by native_decide
example : gates.all (fun g => g.requiredCount > 0 && g.requiredCount <= g.members.length) = true := by native_decide

def topology : LeanFM.ReliabilityDiagram.Topology :=
  { browserLabel := "Browser\\\\React document board"
  , seriesPools := pools
  , shards := shards
  , gates := gates }

def tex : String := LeanFM.ReliabilityDiagram.renderTeX topology
end RuntimeDiagram

def main : IO Unit := do
  IO.FS.writeFile "book/generated/runtime-actor-network.tex" RuntimeDiagram.tex
  IO.FS.writeFile "book/generated/runtime-actor-network-provenance.txt" (reprStr RuntimeDiagram.output ++ "\n")
  IO.println "ok: runtime actor topology generated from typed populations and gates"
