# GoServer example

This is a sanitized snapshot of the GoServer project developed through the
LeanFM browser UI: a KGS-like Go server with n-player Go as an explicit design
goal. It preserves the project book, candidate LeanFM requirements, protobuf
schema, implementation notes, early Go code, and representative stakeholder
media.

The snapshot is an example, not an accepted or completed implementation. In
particular, some early Go code still clamps games to two players and the
committed `requirements.pb.go` identifies itself as a hand-written stand-in.
Those contradictions must be resolved through the two LeanFM acceptance gates
before this is presented as conforming software.

No files from `data/accounts/`, no password verifier, encrypted API key,
session bearer, private conversation, or runtime log are part of this example.
