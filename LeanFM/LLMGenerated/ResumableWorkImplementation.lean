import LeanFM.LLMGenerated.ResumableWork
import LeanFM.ChatUI.Implementation

namespace LeanFM.LLMGenerated.ResumableWorkImplementation
open LeanFM
open LeanFM.ChatUI.Implementation

def decisions : List ImplementationDecision :=
  [ decision "checkpoint-provider-batches"
      ["property:Batch exhaustion preserves requested work", "property:Only the requested scope is continued"]
      ["LeanFM/ChatUI/Provider.lean", "LeanFM/ChatUI/Server.lean"]
      "Run at most four provider rounds per HTTP batch. Return a typed checkpoint instead of a step-limit failure. Preserve completed tool results and the OpenAI response frontier or Anthropic message frontier. Keep task-scoped failed-tool receipts, validation revisions, actual progress and cumulative usage across batches; charge every provider round exactly once. Compact oversized provider context into the original task plus current durable project context and verified receipts, never replay completed mutations."
      ["both-provider HTTP fixtures require more than sixteen rounds and complete across several bounded requests", "usage totals and tool receipts match exactly across checkpoints", "unchanged failures and no-progress cycles stop without resetting their brakes"]
  , decision "project-owned-work-store"
      ["proof:No replay or cross-caller continuation", "proof:No reset of safety or acceptance across batches", "proof:No continuation without useful progress"]
      ["scripts/chatui_work_state.py", "scripts/chatui_command.sh", "LeanFM/ChatUI/Store.lean", "LeanFM/ChatUI/Server.lean"]
      "Persist bounded work records and cached batch receipts atomically below the protected project path .leanfm/work. Use server-issued opaque checkpoint IDs, full one-way caller-session and credential tags, caller account and captured model/provider; never persist a bearer or provider key. Consume a checkpoint before a paid request and retain running/uncertain state after an ambiguous failure. Replay returns a stored receipt or rejects without spending. Serialize project writes with the existing writer lock and a thirty-second inter-batch reservation; expired reservations pause rather than discard work. Detect intervening project revisions before continuation and require an explicit restart from durable files. A new login requires explicit authenticated resume under the same account and retained credential; changed credentials cannot reuse a provider frontier. Exclude work records from model writes, patches, acceptance controls and served file routes."
      ["unit tests cover atomic consume cached replay cross-caller/model/project rejection malformed and escaping paths", "HTTP tests cover two clients replaying one checkpoint and unrelated writes during a live reservation", "restart or HTTP loss cannot replay an uncertain paid batch", "project deletion removes all work state"]
  , decision "client-work-scheduler"
      ["property:Batch exhaustion preserves requested work", "property:Only the requested scope is continued", "proof:No continuation without useful progress"]
      ["ui/src/main.tsx", "ui/src/types.ts", "ui/src/api.ts", "LeanFM/ChatUI/Server.lean"]
      "Keep one captured queued prompt active while the client awaits successive successful checkpoint responses. Use a stable initial request ID and server-issued work/checkpoint metadata on the existing chat route. Reconcile interrupted HTTP responses through a read-only owner-authorized work status route before any further submission. Do not synthesize extra user messages, release later queued prompts early or derive scheduling authority from assistant prose. Preserve the mounted project and phase views and show real batch progress with Cancel throughout. Stop automatic work at completion, a concrete blocker, human questions or gates, cancellation, ended credentials or cumulative session exhaustion. Closing the client starts no subsequent batch."
      ["real Chrome scenario exceeds the former cap, keeps one user message and delivers the final artifact", "queued prompts stay ordered across batches and project navigation", "Cancel between batches and credential changes prevent another provider call", "legacy completed responses remain compatible"]
  , decision "completion-and-failure-boundaries"
      ["property:Only the requested scope is continued", "proof:No reset of safety or acceptance across batches"]
      ["LeanFM/ChatUI/Server.lean", "scripts/chatui_specification.py", "scripts/chatui_command_runner.py"]
      "Keep real local compiler failures distinct from a normal batch boundary. Use the bounded two-thread canonical compiler and stop immediately on unavailable-worker results. Application checks require an explicitly provided target and cannot substitute for specification validation. A requested requirements/implementation/source outcome must satisfy its existing artifact and check controls before final success; incomplete work with useful verified progress yields another batch. Formal requirements and implementation acceptance remain exclusively human-controlled. Preserve cancellation and accounting across all batches and never reinterpret transport timeout incomplete output or a local worker failure as a resumable provider response."
      ["compiler thread startup and absent-build-target regressions", "both provider protocols stop before another paid request on unavailable worker", "empty specification and premature source generation cannot be marked complete", "both existing human acceptance gates remain independent"] ]

def errors : List String :=
  let known := requirementReferenceIds LeanFM.LLMGenerated.ResumableWork.spec
  decisions.flatMap fun item =>
    item.requirementRefs.filterMap fun ref =>
      if known.contains ref then none else some ("unknown resumable-work requirement: " ++ ref)
end LeanFM.LLMGenerated.ResumableWorkImplementation
