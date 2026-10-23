# ChatUI specification workflow repair

This repairs the existing `chat_layers_mutate_only_their_artifacts`,
`web_ui_replaces_external_coding_session`, `reversible_defaults_prevent_interrogation_loops`,
`selected_project_context_drives_chat`, and `diagram_is_task_local` contracts.
It does not accept a project specification or change its wire behavior.

Positive invariant: every specification check evaluates the selected project's
canonical typed requirements and derives its task views from that same value;
ordinary chat can advance those files without rewriting the entire book.

The checker MUST NOT read credentials or other projects, write implementation
source, accept stakeholder gates, execute with network access, promote failed or
stale views, or launch provider repair requests. A changed canonical specification
MUST NOT be reported as successful without a current successful check.

Protected assets are project files, prior valid views, account credentials,
acceptance records, and the operator's provider budget. Project/model-authored
Lean is executable and untrusted at the host boundary.

| Forbidden behavior | Control | Negative evidence |
| --- | --- | --- |
| Read credentials or another project through Lean evaluation | Network-disabled bubblewrap; mount selected project, installed Lean and compiled LeanFM libraries read-only, only scratch writable; fresh environment without credentials | `chatui_specification_test.py`: outside file, environment and network isolation |
| Escape through a path, symlink, or injected Lean identifier | Fixed canonical input paths; reject symlink components; dotted-identifier allowlist; no shell interpolation | identifier and input/output symlink rejection tests |
| Replace valid views after compilation or structural validation fails | Generate catalog in project-local scratch; validate JSON; atomic promotion only after success | failed compile, invalid grammar and unchanged catalog tests |
| Report stale or host-default task views as project evidence | Compile current canonical source every time; use its named RequirementSpec; record source/proto digests and renderer provenance | project-specific messages and second-revision tests |
| Consume unbounded resources or invoke paid repairs | Finite subprocess deadlines, address-space/CPU/file/output limits and project-local scratch; no provider call in checker | timeout/resource controls and HTTP fixture request counts |
| Infer acceptance or mutate implementation during requirements validation | Checker touches only project-local scratch, task catalog and check report; instruction preserves both gates | acceptance/source byte preservation tests |
| Force a full-book output for a specification or implementation request | Guided prompt selects artifact work; book envelope retained only for actual book revision | both provider protocol fixtures assert no forced envelope and invoke real tools |

Existing authenticated project routing, request-local provider credentials,
cancellation and repeated-tool-failure brakes remain applicable. Checks establish
elaboration, structural validation and view provenance, not deployed-code
refinement or stakeholder acceptance.
