# Blank reconstruction experiment: Gate 1, run 2

Run 2 tested the repaired distribution boundary: the PDF remained the only
product-design input, while the clean room also received the generic LeanFM
authoring library, local reference and interrogation commands, the validator,
and a renderer that consumes the exported `RequirementSpec`.

## Result

The structural bootstrap succeeded.

- The fresh agent produced a real `LeanFM.RequirementSpec` rather than an
  unrelated Lean lookalike.
- It reconstructed the canonical protobuf envelope tags, nested content types,
  and repeated fields from the new normative schema in Part III.
- `make check` passed LeanFM validation and protobuf compilation.
- Ten interaction diagrams and ten residual state machines were generated from
  the typed requirement value by the supplied renderer.
- No implementation specification or application source was created before
  acceptance.

This directly repairs the principal failure from run 1.

## Remaining criticism

1. The generic validator requires positive population and resource numbers,
   while the book does not yet specify deployable values. The agent used `1` as
   an explicitly disclosed placeholder. A value that passes a validator but is
   not proposed for acceptance is dangerous. Either the book must state an
   initial operational profile or the language needs a first-class unresolved
   bound that prevents acceptance without masquerading as a real number.
2. The generic scalar message table cannot represent repeated or nested field
   cardinality. The protobuf is canonical, but agreement between it and the
   Lean value is not fully checked.
3. The reconstructed Lean file is compact to the point of poor reviewability.
   Passing the structural validator does not establish the security,
   concurrency, containment, or liveness claims in prose.
4. The run consumed 128,272 model tokens. The exact schema removed important
   guessing, but the PDF remains expensive to reinterpret. A generated
   machine index should accompany the narrative without becoming an answer-key
   copy of the product requirements.
5. Sixteen genuine product ambiguities remain, including authentication policy,
   session lifetime, deletion recovery, research URL safety, revision conflict
   semantics, and accessibility conformance.

## Revised success criterion

The public handoff is: give a person the PDF URL and ask Claude, Gemini, Codex,
or another capable construction agent to build LeanFM. The construction agent
may download the generic bootstrap named by Part III. The delivered result must
be a standalone web server: users work through its browser UI and supply their
own model-provider credentials. Codex and the construction conversation are
not runtime dependencies.

Run 2 proves that this distribution can now reach a checked Requirements Gate
1. It does not yet prove the complete PDF-to-standalone-server claim; that
requires explicit acceptance of the revised requirements, a separately
accepted implementation specification, and the final clean-room implementation
pass.
