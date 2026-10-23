# Chat image and regression conformance review

Prompt: attach an image in chat and let the selected LLM see it.
Existing requirements: multimodal content and project-local media in
LeanFM/ChatUI/Requirements.lean; MediaUploaded/MediaRendered and
ChatPromptSubmitted in Requirements.proto; realization in Implementation.lean.
This completes those mappings; it does not accept another project's gates.

Positive invariant: every submitted image turn supplies its immutable,
validated, owning-project pixels to the captured model and retains a visible,
reusable project-relative reference.

Trust boundaries: browser uploads, authenticated account/project routing,
project filesystem, bounded decoder process, and user's selected provider.
Protected assets: other projects, retained credentials, filesystem outside the
project root, model billing identity, and finite memory/CPU/disk.

| Forbidden behavior | Control | Negative evidence |
| --- | --- | --- |
| Read/upload another project's image | Existing project authorization; resolve IDs only below that root | Multi-provider HTTP isolation and unauthorized upload/download tests |
| Use filenames as filesystem paths or follow an escaping symlink | Generated 32-hex IDs, fixed paths, component and file symlink rejection | Media traversal, foreign-root and symlink tests |
| Execute SVG or fetch local/network resources | Static element allowlist, defused XML, attribute/reference rejection, deny-fetch rasterizer; display normalized PNG | Script, event, external href, CSS URL, DTD/entity and namespace tests |
| Accept a mislabeled, corrupt or oversized file | Actual decoder type verification, byte/pixel/edge limits, fixed safe errors | MIME mismatch, truncation, byte/pixel limit tests |
| Exhaust decoder or project resources | Process address-space/CPU/wall limits, preview limit, locked disk quota, atomic publication | Quota and malformed-input tests; all negative uploads preserve existing artifacts |
| Switch image/model when a later prompt is edited | Queue captures complete stable references and model; resend uses persisted references | Browser upload/removal/send/resend checks and both native provider payload checks |
| Send only a filename and claim vision input | Provider-native pixel content blocks, labeled first GIF frame | Stub decodes actual pixels from both providers' HTTP requests |
| Leak uploaded data through error output | Fixed decoder errors; numeric provider-round logs only | HTTP failure and existing diagnostic secrecy tests |
| Lose saved credentials on service restart | Password-encrypted persistent bundle; restart invalidates unlocked session only | Password-only two-provider login after actual service restart |
| Substitute host grammar for a project task | Explicit owning specification in renderer and serializer | Foreign task with colliding ID has no host messages or missing-grammar placeholder |

Provider schemas checked against official OpenAI Images and vision and
Anthropic Vision documentation on 2026-10-23. No real provider calls or paid
requests are needed for conformance tests.
