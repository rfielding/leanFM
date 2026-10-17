# Requirements Gate 1 validation evidence

Validated in `/tmp/leanfm-reconstruction-v2.ZvNgHv` on 2026-10-15.

Commands required before authoring:

- `make reference` — passed; complete requirement-language reference read.
- `make interrogation` — passed; complete interrogation checklist read.

Final command:

```text
$ make check
Build completed successfully (5 jobs).
Build completed successfully (6 jobs).
ok: all generated requirements are well-formed typed Lean values
Build completed successfully (6 jobs).
ok: rendered 10 interaction diagrams and state machines from RequirementSpec
```

The check comprises Lean elaboration, `LeanFM.generatedRequirementValidationReport`, protobuf descriptor compilation with `protoc`, and generation of both review documents by `bootstrap/RenderRequirements.lean` from `LeanFMProject.Requirements.spec`.

Renderer compatibility note: the supplied renderer used the reserved identifier `section` under Lean 4.28. Its helper was renamed to `diagramSection`; behavior was otherwise unchanged.
