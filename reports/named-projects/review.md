# Readable project directories

Prompt: “name the directory after the project. a long hash makes it impossible
to see what it is.” The selected project is GoServer. The operator requests its
reversible relocation from `projects/e7fdeae8572f7c9f` to `projects/GoServer`.

Positive invariant: every manifest project identity resolves to exactly one
exclusive project root, independently of its readable directory label and the
visitor's credential account. A directory-only relocation preserves every
project byte, existing URLs, checked specification and acceptance revisions.

New project directories use the supplied display name with ASCII letters,
digits, hyphens and underscores. Other characters become hyphen separators;
labels are bounded, retain name case and use a short numeric suffix on
collision. A name without usable characters defaults to `Project`. These are
reversible engineering defaults, not another stakeholder questionnaire.

The fixed workspace command reserves a root with atomic `mkdir`. It cannot
adopt an existing directory or follow a symlink, and avoids every manifest ID
already held by another named root. Runtime and portable manifests are scanned
only one directory below `projects/`. The manifest identity controls lookup;
duplicate identities fail closed and are excluded from the catalog. Deletion
uses the same resolver and retains exact display-name confirmation. The
read-only self-hosting identity `leanfm-workspace` cannot be allocated.

The canonical requirements delta is
`LeanFM/LLMGenerated/SharedProjects.lean:readable_project_directories_preserve_identity`.
Its implementation mapping is the `shared-workspace-paths` decision in
`LeanFM/LLMGenerated/Implementation.lean`. Existing project-owned specifications
and human gate records are not rewritten or accepted by a directory move.
Historical fresh-start acceptance evidence remains unchanged.

| Forbidden behavior | Control | Negative evidence |
| --- | --- | --- |
| Naming overwrites or merges existing state, including concurrent equal names | Atomic reservation; collision suffixes; reserve all existing manifest identities | Concurrent reservation and sentinel tests; API duplicate after relocation |
| A rename changes identity, URLs, source or acceptance | Manifest-based lookup; atomic whole-directory relocation; no project-content rewrite | Per-file byte inventory; old-ID API reads and unchanged specification state |
| Ambiguous copies resolve to an arbitrary project | Reject duplicate manifest identities | Duplicate-ID resolution/listing/allocation tests |
| Project names or manifests escape to keys or another project | Bounded safe labels; reject symlink roots/manifests and escaping configured paths; fixed argument-vector command | Traversal, shell-shaped name, symlink, configured-path and reserved-host tests |
| Confirmed deletion deletes the wrong named root | Resolve stable ID; require exact display-name confirmation and immediate-child root boundary | Wrong confirmation keeps root; correct deletion removes only selected moved root |
| Relocation overlaps active paid work or drops files | Quiesce the selected project, preflight destination, compare complete relative byte inventory and existing gate state | Live relocation evidence recorded after execution |

No project source-generation work, credential change or provider inference is
part of this naming repair.

The retained project lifecycle interaction and state diagrams are generated
from `LeanFM.LLMGenerated.SharedProjects.spec`, using its
`shared-projects.projects.interaction` and `shared-projects.projects.state`
DesiredOutput records and the reducers in `ReviewSharedProjects.lean`. Naming
changes manifest resolution, not the project-operation message grammar.

Verification: `make check`, `make book`, five naming/confinement tests, two
workspace-reset tests, the production browser flow, all 27 multi-provider tests,
five shared-project API tests and six HTTP tests passed. The API regression
opens a moved root through its original identity for multiple callers, checks
unchanged specification state, and deletes only that root after exact name
confirmation.

GoServer was idle before the service stopped. Atomic relocation preserved all
2,219 existing project entries, their bytes and modes, and both checked gate
revisions. Its old-ID PDF URL returned HTTP 200 after the tested service restarted;
pre/post specification state matched exactly. Detailed inventory and migration
evidence remain inside the project's own `reports/root-rename/`, outside the
LeanFM repository commit. The operator requested a pause to inspect the generated
application; no generated GoServer source was changed by this naming repair.
