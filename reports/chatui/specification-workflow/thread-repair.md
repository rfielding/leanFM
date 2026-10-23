# Bounded specification worker repair

Prompt: requirements generation stopped with `failed to create thread` (exit
134), then an unrelated `make build` failed because the project has no Makefile.

Positive invariant: local canonical specification validation can start under
the existing resource limits and either derive current project views or return
the actual compiler/validation diagnostic. Local infrastructure failures must
stop paid continuation before another provider round.

The real GoServer source imported `LeanFM`; the worker used host-sized automatic
threading under a 3 GiB address-space limit. The original failure was reproduced
inside the production sandbox. Passing `-j2 -M2048` makes that same source compile
without increasing the address-space, CPU, file, network or write permissions.
Validation then correctly reports that the current saved RequirementSpec is
still an empty scaffold. No generated game requirement or gate acceptance is
claimed from this runtime repair.

| Forbidden behavior | Control | Evidence |
| --- | --- | --- |
| Evade the failure by removing sandbox or resource limits | Fixed compiler thread count and compiler memory ceiling within the unchanged worker limits | Real full-`LeanFM`-import regression and existing environment, outside-file, write and network isolation tests |
| Call a model to repair local worker startup or blindly substitute an application build | Dedicated unavailable-worker result; both provider protocols stop on fatal tool results; explicit tool guidance | Fault-injected worker exit 134 maps to exit 78 while preserving the last good catalog; provider fatal-result checks |
| Run an unprovided build target or execute Makefile discovery on the host | Bounded static ordinary-Makefile declaration check before launch; clear instruction to use `leanfm_check` for specs | Missing-Makefile/target tests include an executable Make expression that must not run |
| Accept empty requirements, promote invalid views or cross a human gate | Existing structural validation and atomic promotion retained | Real project now reaches the empty-requirement diagnostics; last-good-view and unchanged-gate regressions |

The original project-specific diagnostic is retained below that project's own
`reports/specification-check/recovery/` directory. No project state or account
credential is copied into this repository-level report. Checks use local
compilers and disposable fixtures; no paid model request is made by the repair.

Executed validation: `make check`; eight specification-worker tests; three
command/isolation tests; `ProviderTests.lean`; the production Chrome workflow
and full local HTTP suite, including 22 multi-provider tests. Both real provider
adapters stop on the injected worker failure after exactly five fixture rounds,
without a sixth paid continuation. No live account inference was used.
