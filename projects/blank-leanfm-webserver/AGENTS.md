# Blank LeanFM reconstruction experiment

This directory is an isolated LeanFM project. Treat `book/main.pdf` (or the
equivalent accessible `book/main-dark.pdf`) as the only product-design
specification. The generic authoring library in `LeanFM/`, the programs in
`bootstrap/`, `lean-toolchain`, and `lakefile.toml` are permitted language
inputs. They define how to express and validate a design; they contain no prior
web-server requirements or implementation.

Do not inspect, import, copy, search, or infer from the original LeanFM
repository outside this project root, its application source, prior web-server
requirements, implementation specification, Git history, or prior
conversations. If this directory remains nested in a LeanFM checkout, copy it
to an unrelated directory before starting the test. Files already inside this
project are deliberate experiment inputs.

Before authoring requirements, run `make reference` and `make interrogation`
and read their complete output. Do not invent a replacement DSL. The candidate
must import `LeanFM.Artifacts`, use namespace `LeanFMProject.Requirements`,
define `spec : LeanFM.RequirementSpec` and
`all : List LeanFM.GeneratedRequirement`, and validate with `make check`.
Generated interaction and state-machine review files must come from
`bootstrap/RenderRequirements.lean`, not separately authored Markdown.

The objective is to determine whether a fresh agent can reconstruct a useful
LeanFM web server from the book.

Use two explicit gates:

1. Derive `Specification/Requirements.lean` and
   `Specification/Requirements.proto`, their interaction diagrams, state
   machines, and validation evidence. Stop for explicit requirements acceptance.
2. After that acceptance, derive `Specification/Implementation.lean` with full
   traceability and stop for explicit implementation acceptance.

Only after both acceptances may source code and tests be written. Do not seed
the specification from an implementation. Record every ambiguity or missing
book requirement in `evidence/ambiguities.md`; do not silently fill it from
outside knowledge of LeanFM.

All project-owned state must remain below this directory.
