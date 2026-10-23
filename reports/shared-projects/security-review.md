# Shared-project storage and access review

Status: proposed requirements and implementation mappings; migration and runtime
tests have not run. This review accepts neither gate.

The stakeholder explicitly confirmed that projects open without login, while
LLM calls require login. The positive invariant is one complete shared project
root under projects/<id>, independent of account identity, with each provider
call using only its initiating caller's unlocked API key.

Trust boundaries are the browser origin, loopback HTTP admission, shared
project path/manifest resolution, the separate credential vault, queued and
concurrent model work, provider requests, and the stopped-runtime migration.
Protected assets include encrypted account records and passwords, unlocked
keys and sessions, existing project files and accepted revisions, writer
integrity, and the identity charged for model use.

| MUST NOT behavior | Proposed implementation control | Required negative evidence |
| --- | --- | --- |
| Expose credential files through a shared project | Separate .leanfm/accounts vault; canonical root and manifest-path checks; omit vault from discovery/file/tool routes | Anonymous and alternate-account requests cannot read ciphertext, verifiers, bearers or keys; traversal/symlink/manifest escape tests |
| Let another web page mutate the unsigned workspace | Central local Host and Origin/Sec-Fetch-Site admission before unsafe dispatch | Cross-site form/fetch, missing/spoofed Host and DNS-rebinding cases cause no file change or provider request |
| Bill a different caller after a login or key change | Capture queued credential identity/model; hold unstarted paid work on credential changes; recheck session before every provider/tool step | Queue under A then log out, rotate keys or sign in as B; no A prompt is sent with B's key |
| Lose shared edits or overlap model tools during relocation | Coordinate conflicting writers by canonical project identity; reject before mutation/spending or serialize bounded work; quiesce migration | Two-account same-project writes, stale editors, deletion/migration during active work and rejected-turn accounting |
| Lose or overwrite a project or saved encrypted key | Full preflight; preserve IDs; atomic whole-root moves and byte/mode verification; reject different existing destinations | Collision, unsupported nonempty input, failed verification, interrupted/repeated migration and password-only unlock after restart |
| Delete an unknown legacy tree | Recognize the observed empty orphan scaffold explicitly; recheck and remove only empty leaves with rmdir | A newly added file blocks cleanup; every nonempty unknown root remains untouched |
| Break active paths or prior diagrams during movement | Repair only active hard-coded helpers; preserve historical evidence and regenerate current views from canonical specifications | No active legacy path remains; project IDs/URLs and generated task diagrams still work after relocation |
| Change media/framing/resource controls while sharing roots | Retain the existing image decoder limits, safe SVG normalization, HTTP framing/deadlines and bounded diagnostics | Existing negative media, provider protocol, malformed HTTP and secret-free diagnostics suites adapted to shared-project semantics |

The filesystem preflight found one valid legacy project, three private account
records, four existing manifest-bearing project roots and one empty orphan
scaffold. There are no current destination conflicts. The preflight is a
read-only observation; quiescence and revalidation are required before moving.

Proposed runtime evidence belongs in scripts/chatui_shared_projects_test.py,
scripts/chatui_storage_migration_test.py, and the updated existing browser,
provider and HTTP suites. Structural Lean/protobuf validation and successful
book rendering are current evidence; they do not prove these runtime controls.
