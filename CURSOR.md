# Using a Cursor subscription with LeanFM

Cursor is an agent client, not a model-provider API key to store in LeanFM.
Authenticate Cursor with the account that owns the subscription, run LeanFM,
and open this project directory in Cursor:

```sh
cursor-agent login
make serve
cursor-agent mcp list
cursor-agent mcp list-tools leanfm
cursor-agent
```

The committed `.cursor/mcp.json` connects Cursor Agent to the local LeanFM MCP
endpoint at `http://127.0.0.1:8080/mcp`. Cursor also reads the root `AGENTS.md`.
A fresh chat therefore needs only this project directory. If the project has no
durable problem statement, the first substantive question is: "What problem
are you trying to solve?"

The MCP surface is currently read-only. Cursor can read the book, canonical
specifications, language references, interrogation prompt and validation
evidence. Cursor edits project files with its normal filesystem tools; the
user reviews and commits those changes with git.

## Driving Cursor from the LeanFM browser

Cursor CLI also offers ACP over newline-delimited JSON-RPC on stdio:

```sh
cursor-agent login
agent acp
```

A future LeanFM `CursorACP` provider adapter can start that process, initialize
and authenticate it, create or load one Cursor session for one LeanFM project
conversation, submit prompts, stream updates, answer permission requests, and
cancel work. Cursor remains responsible for subscription authentication and
billing. LeanFM must never ask for, persist, or reinterpret Cursor's login token
as a model-provider API key.

The adapter must preserve `(user, project, conversation, request)` identity,
bound its queues, keep ACP processes and sessions isolated, expose usage when
Cursor reports it, and terminate the child process when its queue is closed and
drained. File mutations are reviewed and committed with git.
