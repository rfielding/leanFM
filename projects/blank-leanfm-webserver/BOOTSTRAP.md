# First prompt for a new conversation

The long form below is retained as an executable bootstrap test. The intended
normal prompt is only: "Open this project directory with LeanFM." The project
root, its manifest, repository instructions, book and canonical artifact paths
must supply everything else. If no durable problem statement exists, begin by
asking what problem the stakeholder is trying to solve; then ask focused,
named ambiguity questions until the two acceptance gates can be reached.

Start from a blank state and reconstruct the LeanFM web server described by
`book/main.pdf`. Use `book/main-dark.pdf` if that is easier to read; it is the
same book.

Do not inspect or reuse any original LeanFM application implementation or prior
web-server specification, even if this project was copied from inside such a
repository. The book is the only product-design input. The generic `LeanFM/`
authoring library and `bootstrap/` tools are explicitly permitted language and
validation inputs. Treat the book as maintained system-prompt context, not
merely human documentation.

Run `make reference` and `make interrogation` before writing anything. Use the
real `LeanFM.RequirementSpec` language exactly as described. Do not create a
standalone Lean lookalike. Use namespace `LeanFMProject.Requirements`, expose
`spec` and `all`, then run `make check`; its renderer must produce the review
diagrams from the typed value.

First perform requirements discovery. Create complete, durable
`Specification/Requirements.lean` and `Specification/Requirements.proto` plus
generated interaction diagrams and state machines. Record book ambiguities and
missing requirements explicitly. Do not write the server yet. Stop and ask for
explicit acceptance of the observable requirements and derived views.

After acceptance, create a separate, traceable
`Specification/Implementation.lean`. Stop again for explicit acceptance. Only
after both gates, implement the server and tests in one pass and report what the
book was and was not sufficient to reconstruct.
