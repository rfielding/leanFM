# A Lean tutorial for LeanFM

`leanfm-lean-tutorial.mp4` (narrated) teaches Lean as a programming language, then the LeanFM
language written in it. Most Lean tutorials are about proofs; LeanFM is mostly programs, so part one
covers the Lean the codebase actually uses, in the proportions it uses it (the counts on screen are
measured from the tracked `.lean` files).

Part one, Lean:

- `def`, function types, `fun` and `·`; `structure` with defaults, `{ p with … }`, `deriving`;
- `inductive` and `match`, with the missing-case error;
- `Option` (no null) and `Except` with `do` and `←` (no exceptions in pure code);
- lists, arrays, `|>`; `Id.run do` with `let mut` and `for`; strings, `s!` and `include_str`;
- `IO` and `main`; namespaces, dot notation and `«»`; type classes, `instance`, `ToJson`/`FromJson`;
- termination and `partial`; `#guard` tests that are compile errors;
- proofs as values (`rfl`, `decide`, `omega`), structures that carry proofs, `sorry`;
- `syntax` and `macro_rules`, and how LeanFM's commands are added with a non-reserved leading word.

Part two, LeanFM: a `.leanfm` file is a Lean file; message lines piece by piece; where clauses typed
by Lean; `par`, `rec`/`continue`, `include`, `sessions` and events; versions and their upgrade path;
CTL as s-expressions, parsed and formatted by `explain_formula`; `session_ctl` and `session_conform`;
the requirements list, its checked readings, and an implementation with evidence, its own CTL and
hints.

Where everything comes from:

- `Tour.lean` holds every Lean snippet, one `--@scene` region per scene. `make video-check` compiles
  it (with `protocols/`), so the tutorial stays true as Lean and LeanFM change.
- `mistakes/` holds the files that must fail; `fetch.py` refuses to continue if one compiles.
- `protocols/` holds the constructs and versions examples; the Orders example is `examples/orders`.
- `fetch.py` asks `lake env lean --json` for every result and error, and the running service
  (`make serve`) for every diagram, check, verdict and formatted formula, and keeps them in `data/`.
- `produce.py` draws only those answers, narrates with the project-local Piper voice and scores the
  video as `video/ctl-where` does.

```sh
make serve                                     # in another terminal
python3 -I video/lean-tutorial/fetch.py
video/.conda/bin/python -I video/lean-tutorial/produce.py
ONLY=carry video/.conda/bin/python -I video/lean-tutorial/produce.py   # one scene's still, in build/
```
