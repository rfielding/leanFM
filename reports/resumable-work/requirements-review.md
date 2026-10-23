# Resumable ChatUI work

Prompt: break simple tasks into smaller steps and use the client to continue
them, instead of terminating at an arbitrary tool-step limit.

One Send owns the original task, selected project, caller and model. The server
does a bounded batch, saves the continuation and returns progress. The mounted
client starts the next batch automatically. There is no total tool-step cap on
that requested task. Queued prompts wait for the whole task, while other project
views remain usable. Closing the client stops new batches after the current
batch reaches its boundary; a retained checkpoint allows explicit recovery.

The client stops when the requested outcome is complete, a real blocker occurs,
the user cancels, a human decision or either formal acceptance gate is required,
the initiating credential ends, or the existing cumulative session token budget
is exhausted. A tool-count checkpoint is ordinary progress, not a warning.

Positive invariant: useful authorized work survives every internal batch
boundary and continues toward the original requested outcome.

Forbidden outcomes: duplicate paid calls or file writes from checkpoint replay;
another caller/project/model resuming the work; resetting token usage, failure
brakes or cancellation between batches; silent gate acceptance; continuing
unchanged failures forever; treating timeouts or incomplete provider output as
safe checkpoints; storing raw provider keys or login bearers in project files;
or expanding the requested scope merely because work can continue.

Existing clients and ordinary completed-chat responses remain compatible. The
new client trusts server-issued continuation metadata, never a model-written
instruction hidden in answer text.

Wire compatibility requirements: keep `POST /api/projects/{id}/chat` and its
existing completed-response fields. A client may add a stable request ID when
starting work. A successful partial response adds server-issued work ID,
checkpoint ID, batch/progress metadata and a continuation-needed flag. A
continuation submits those IDs to the same project chat route without adding a
second user prompt. A read-only work-status route lets the same caller reconcile
an interrupted HTTP response before doing anything billable. Existing project
Cancel applies to the entire work item. Stale, foreign or mismatched continuation
requests fail before a paid call; replay can return an already stored receipt,
but must never execute that batch again. An ambiguous in-flight provider request
is reported as blocked, not automatically retried. A new login requires an
explicit resume decision rather than silently spending on an old task.

Typed candidate: `LeanFM/LLMGenerated/ResumableWork.lean`.
Derived [interaction](work.interaction.mmd) and [state machine](work.state.mmd)
answer the prompt above; their event source, reducer, unit and task boundary are
recorded in the candidate's DesiredOutput values. They are design views, not an
observed throughput or billing claim.

Requirements acceptance: pending. The separate implementation mapping must be
accepted independently before implementing the continuation protocol.
