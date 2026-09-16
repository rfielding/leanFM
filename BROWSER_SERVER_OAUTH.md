# Browser, Server, OAuth Actor Grammar

This note sketches a message-passing model for a browser, application server, and OAuth provider. The source of truth is the visible message trace. Actor state, task state, and session state are derived by folding over messages.

## Actors

Actors are constructed instances, not global singletons:

```lean
inductive Actor where
  | browser : BrowserId -> Actor
  | server : ServerId -> Actor
  | oauth : ProviderId -> Actor
```

Example instances:

```text
Browser(user-agent-1)
Server(app.example.com)
OAuth(accounts.example-idp.com)
```

## Tasks

Tasks are also constructed. A login task creates a session-bearing fact. Application tasks consume that session fact.

```lean
inductive Task where
  | login : BrowserId -> ServerId -> ProviderId -> Task
  | getPage : SessionId -> Route -> Task
  | callApi : SessionId -> ApiRoute -> Task
```

## Messages

Each visible event has a task, source actor, destination actor, and message atom.

```lean
structure Event where
  task : Task
  src : Actor
  dst : Actor
  msg : Msg
```

The useful alphabet is:

```text
(task, src, dst, msg)
```

## Login Grammar

The browser starts at the application server. The server redirects to the OAuth provider. The OAuth provider returns an authorization code to the browser. The browser presents that code to the server. The server exchanges it with the OAuth provider and returns a session to the browser.

```text
login(browser, server, oauth) =
  Browser -> Server : HttpGet /login ;
  Server -> Browser : Redirect authorize_url(state, code_challenge) ;
  Browser -> OAuth : AuthorizeRequest(client_id, redirect_uri, state, code_challenge) ;
  OAuth -> Browser : Redirect callback(code, state) ;
  Browser -> Server : Callback(code, state) ;
  Server -> OAuth : TokenRequest(code, code_verifier, client_secret_or_proof) ;
  (
    OAuth -> Server : TokenResponse(access_token, id_token, subject)
    Server -> Browser : SessionIssued(session_id, subject)
  |
    OAuth -> Server : TokenError(reason)
    Server -> Browser : LoginFailed(reason)
  )
```

The produced fact is:

```text
SessionIssued(session_id, subject)
```

No hidden server login state is required. The session fact is accumulated from the visible trace.

## Session-Bearing Task Grammar

After login, application tasks are guarded by the visible session.

```text
guard trace contains SessionIssued(session_id, subject):
  getPage(session_id, route) =
    Browser -> Server : HttpGet(route, session_id) ;
    (
      Server -> Browser : HttpOk(route, body)
    | Server -> Browser : HttpUnauthorized(route)
    )
```

The same pattern works for API calls:

```text
guard trace contains SessionIssued(session_id, subject):
  callApi(session_id, api_route) =
    Browser -> Server : ApiRequest(api_route, session_id, body_hash) ;
    (
      Server -> Browser : ApiResponse(status, body_hash)
    | Server -> Browser : ApiError(status, reason)
    )
```

## Parallel Tasks

Two session-bearing tasks can run in parallel when neither consumes a fact produced by the other and they do not conflict on a bounded queue/resource.

```text
login ;
parallel(
  getPage(session, /home),
  callApi(session, /notifications)
)
```

Completion order commutes:

```text
getPage.done ; callApi.done
```

is equivalent to:

```text
callApi.done ; getPage.done
```

when both tasks depend only on the same prior `SessionIssued` fact.

## Required Proof Shapes

The common proof obligations map to trace predicates:

```text
Never p       = AG not p
Always q      = AG q
Eventually r  = AF r
Possibly s    = EF s
```

Useful OAuth properties:

```text
Never session_without_token:
  no SessionIssued(session_id, subject) unless TokenResponse(access_token, id_token, subject) occurred earlier.

Always callback_state_matches:
  every Callback(code, state) must match an earlier Redirect authorize_url(..., state, ...).

Eventually login_terminal:
  every login task eventually reaches SessionIssued or LoginFailed.

Possibly token_error:
  there exists a legal trace where OAuth returns TokenError and the browser receives LoginFailed.
```

## Zoom Levels

Collapsed login node:

```text
login
P(success)=...
E(latency)=...
AF terminal=true
AG callback_state_matches=true
```

Expanded login grammar:

```text
Browser -> Server : HttpGet /login
Server -> Browser : Redirect authorize_url
Browser -> OAuth : AuthorizeRequest
OAuth -> Browser : Redirect callback
Browser -> Server : Callback
Server -> OAuth : TokenRequest
OAuth -> Server : TokenResponse | TokenError
Server -> Browser : SessionIssued | LoginFailed
```

Implementation refinement can expand any message into lower-level events while preserving the parent grammar's boundary behavior.
