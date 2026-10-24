# Resumable-work status

Both specification gates were explicitly accepted. `acceptance.json` records
the user answers and exact reviewed artifact hashes. The reviewed documents
retain their pre-acceptance wording so those bytes remain verifiable; the
acceptance record is authoritative for gate status.

The typed requirements, derived views and separate implementation mapping are
checked. Runtime implementation is **paused at the user's explicit request** and
committed as `9230c4b` on `work/resumable-chatui-20261023`. All repository-owned
work is committed; live projects, encrypted keys, logs and caches remain local.

The runtime branch passes `make check`, `make book`, the production Chrome
workflow and all 23 multi-provider tests, including tasks beyond sixteen rounds
and replay call-count checks. One later HTTP shell check remains unresolved;
the branch's `pause-checkpoint.md` records the observed fixture mismatch and
resume instructions. The runtime is not merged into this verified main branch
and has not been deployed. Resume only when the user requests it.
