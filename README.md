# leanFM

Lean Formal Methods, based on communicating heirarchial processes.

## Checkable requirements in Lean

This repository now includes `/home/runner/work/leanFM/leanFM/Requirements.lean`, a small Lean file for
capturing accepted requirements as proof-carrying artifacts.

- `RequirementDraft` is the place to encode a requirement being refined with an LLM or stakeholder.
- `AcceptedRequirement` is the Lean-checked form that can be committed into the repository.
- Each accepted requirement must carry a proof, so `lean Requirements.lean` fails if a requirement is
  committed without a valid formalization.

To check the committed requirements locally:

```bash
lean /home/runner/work/leanFM/leanFM/Requirements.lean
```
