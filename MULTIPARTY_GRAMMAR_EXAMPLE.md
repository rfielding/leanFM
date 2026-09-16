# Multiparty Grammar Working Example

This example models a browser, application server, and OAuth provider as a multiparty message grammar. The grammar is CFG-like for readable protocol shape, with context-sensitive guards for facts such as "this session was issued earlier".

The important atom is a visible message event:

```text
(task, src, dst, msg)
```

All state is derived from the accepted message trace.

## Domain Values

```lean
structure BrowserId where
  value : String
deriving DecidableEq, Repr

structure ServerId where
  value : String
deriving DecidableEq, Repr

structure ProviderId where
  value : String
deriving DecidableEq, Repr

structure SessionId where
  value : String
deriving DecidableEq, Repr

structure OAuthState where
  value : String
deriving DecidableEq, Repr

structure OAuthCode where
  value : String
deriving DecidableEq, Repr

structure Route where
  value : String
deriving DecidableEq, Repr
```

## Actors

Actors are constructed instances:

```lean
inductive Actor where
  | browser : BrowserId -> Actor
  | server : ServerId -> Actor
  | oauth : ProviderId -> Actor
deriving DecidableEq, Repr
```

Example:

```text
Browser(b1)
Server(app)
OAuth(idp)
```

## Tasks

Tasks are also constructed instances:

```lean
inductive Task where
  | login : BrowserId -> ServerId -> ProviderId -> Task
  | getPage : SessionId -> Route -> Task
deriving DecidableEq, Repr
```

## Message Atoms

Message atoms are the payload-level names that would later be backed by protobuf definitions.

```lean
inductive Msg where
  | httpGetLogin
  | redirectToOAuth : OAuthState -> Msg
  | authorizeRequest : OAuthState -> Msg
  | callbackCode : OAuthCode -> OAuthState -> Msg
  | tokenRequest : OAuthCode -> Msg
  | tokenResponse : SessionId -> Msg
  | tokenError : String -> Msg
  | sessionIssued : SessionId -> Msg
  | loginFailed : String -> Msg
  | httpGetPage : SessionId -> Route -> Msg
  | httpOk : Route -> Msg
  | httpUnauthorized : Route -> Msg
deriving DecidableEq, Repr
```

## Event Alphabet

Every terminal symbol of the grammar is an event:

```lean
structure Event where
  task : Task
  src : Actor
  dst : Actor
  msg : Msg
deriving DecidableEq, Repr
```

For example:

```text
(login(b1, app, idp), Browser(b1), Server(app), HttpGetLogin)
```

## Grammar AST

The authoring grammar is CFG-like, with guards for context-sensitive facts:

```lean
abbrev Trace := List Event

inductive Grammar where
  | empty : Grammar
  | event : Event -> Grammar
  | seq : Grammar -> Grammar -> Grammar
  | choice : List Grammar -> Grammar
  | par : Grammar -> Grammar -> Grammar
  | guard : (Trace -> Bool) -> Grammar -> Grammar
```

Informally:

```text
seq a b      means a then b
choice xs    means one branch from xs
par a b      means any interleaving that preserves order inside a and b
guard p g    means g is legal only when p holds over the prior trace
```

LeanFM's checked DSL uses ordinary Lean constructors with a regex-like documentation layer:

```lean
def seq := LeanFM.GrammarExpr.seqList
def alt := LeanFM.GrammarExpr.alt

infixr:55 " >>> " => LeanFM.GrammarExpr.seq
infixr:50 " <||> " => fun left right => LeanFM.GrammarExpr.choice [left, right]
```

So a grammar can be written in valid Lean as either list-oriented EBNF:

```lean
seq
  [ event loginTask browser server Msg.httpGetLogin
  , alt
      [ event loginTask server browser (Msg.loginFailed "invalid_request")
      , seq
          [ event loginTask server oauth (Msg.tokenRequest code1)
          , event loginTask server browser (Msg.sessionIssued sess1)
          ]
      ]
  ]
```

or as an infix expression:

```lean
event loginTask browser server Msg.httpGetLogin >>>
  (event loginTask server browser (Msg.loginFailed "invalid_request") <||>
   (event loginTask server oauth (Msg.tokenRequest code1) >>>
    event loginTask server browser (Msg.sessionIssued sess1)))
```

## Concrete Example Values

```lean
def b1 : BrowserId := { value := "b1" }
def app : ServerId := { value := "app.example.com" }
def idp : ProviderId := { value := "accounts.example.com" }
def st1 : OAuthState := { value := "state-1" }
def code1 : OAuthCode := { value := "code-1" }
def sess1 : SessionId := { value := "session-1" }
def home : Route := { value := "/home" }

def browser : Actor := Actor.browser b1
def server : Actor := Actor.server app
def oauth : Actor := Actor.oauth idp
def loginTask : Task := Task.login b1 app idp
def getHomeTask : Task := Task.getPage sess1 home
```

Helper notation:

```lean
def ev (task : Task) (src dst : Actor) (msg : Msg) : Event :=
  { task := task, src := src, dst := dst, msg := msg }
```

## Login Grammar

Successful login:

```lean
def loginSuccess : Grammar :=
  Grammar.seq (Grammar.event (ev loginTask browser server Msg.httpGetLogin)) <|
  Grammar.seq (Grammar.event (ev loginTask server browser (Msg.redirectToOAuth st1))) <|
  Grammar.seq (Grammar.event (ev loginTask browser oauth (Msg.authorizeRequest st1))) <|
  Grammar.seq (Grammar.event (ev loginTask oauth browser (Msg.callbackCode code1 st1))) <|
  Grammar.seq (Grammar.event (ev loginTask browser server (Msg.callbackCode code1 st1))) <|
  Grammar.seq (Grammar.event (ev loginTask server oauth (Msg.tokenRequest code1))) <|
  Grammar.seq (Grammar.event (ev loginTask oauth server (Msg.tokenResponse sess1))) <|
              (Grammar.event (ev loginTask server browser (Msg.sessionIssued sess1)))
```

Failed login:

```lean
def loginFailure : Grammar :=
  Grammar.seq (Grammar.event (ev loginTask browser server Msg.httpGetLogin)) <|
  Grammar.seq (Grammar.event (ev loginTask server browser (Msg.redirectToOAuth st1))) <|
  Grammar.seq (Grammar.event (ev loginTask browser oauth (Msg.authorizeRequest st1))) <|
  Grammar.seq (Grammar.event (ev loginTask oauth browser (Msg.callbackCode code1 st1))) <|
  Grammar.seq (Grammar.event (ev loginTask browser server (Msg.callbackCode code1 st1))) <|
  Grammar.seq (Grammar.event (ev loginTask server oauth (Msg.tokenRequest code1))) <|
  Grammar.seq (Grammar.event (ev loginTask oauth server (Msg.tokenError "invalid_grant"))) <|
              (Grammar.event (ev loginTask server browser (Msg.loginFailed "invalid_grant")))
```

Login as a choice:

```lean
def loginGrammar : Grammar :=
  Grammar.choice [loginSuccess, loginFailure]
```

## Accumulated Facts

The session fact is derived from the trace:

```lean
def containsSessionIssued (session : SessionId) (trace : Trace) : Bool :=
  trace.any fun e =>
    match e.msg with
    | Msg.sessionIssued s => s == session
    | _ => false
```

The token fact is also derived from the trace:

```lean
def containsTokenResponse (session : SessionId) (trace : Trace) : Bool :=
  trace.any fun e =>
    match e.msg with
    | Msg.tokenResponse s => s == session
    | _ => false
```

## Guarded Application Task

The page task is legal only after the session was visibly issued:

```lean
def getHomeGrammar : Grammar :=
  Grammar.guard (containsSessionIssued sess1) <|
    Grammar.seq
      (Grammar.event (ev getHomeTask browser server (Msg.httpGetPage sess1 home)))
      (Grammar.choice
        [ Grammar.event (ev getHomeTask server browser (Msg.httpOk home))
        , Grammar.event (ev getHomeTask server browser (Msg.httpUnauthorized home))
        ])
```

The whole system grammar is:

```lean
def systemGrammar : Grammar :=
  Grammar.seq loginGrammar getHomeGrammar
```

## Example Accepted Trace

This trace is legal:

```text
Browser -> Server : HttpGetLogin
Server -> Browser : RedirectToOAuth(state-1)
Browser -> OAuth  : AuthorizeRequest(state-1)
OAuth  -> Browser : CallbackCode(code-1, state-1)
Browser -> Server : CallbackCode(code-1, state-1)
Server -> OAuth  : TokenRequest(code-1)
OAuth  -> Server : TokenResponse(session-1)
Server -> Browser : SessionIssued(session-1)
Browser -> Server : HttpGetPage(session-1, /home)
Server -> Browser : HttpOk(/home)
```

This trace is rejected because the page request appears before the session fact:

```text
Browser -> Server : HttpGetPage(session-1, /home)
Server -> Browser : HttpOk(/home)
```

## Security Predicates

Security claims are mostly "never this bad shape".

```lean
def sessionIssuedWithoutToken (trace : Trace) : Bool :=
  trace.any fun e =>
    match e.msg with
    | Msg.sessionIssued s => !containsTokenResponse s trace
    | _ => false
```

A stronger version should check ordering, not only presence:

```text
Never SessionIssued(session) unless an earlier TokenResponse(session) exists.
```

Other useful forbidden patterns:

```text
Never HttpOk(route) unless an earlier SessionIssued(session) exists.
Never CallbackCode(code, state) accepted by Server unless Server earlier emitted RedirectToOAuth(state).
Never TokenRequest(code) appears twice.
Never SessionIssued(session) appears on a failed login branch.
```

## Required Proof Modes

Proof declarations map to CTL:

```text
Never p       = AG not p
Always q      = AG q
Eventually r  = AF r
Possibly s    = EF s
```

For this system:

```text
Never sessionIssuedWithoutToken
Always callbackStateMatchesRedirect
Eventually loginTerminal
Possibly tokenError
```

## Parallel Composition

After login, independent tasks may run in parallel:

```lean
def apiTask : Grammar := ...

def afterLoginParallel : Grammar :=
  Grammar.seq loginSuccess (Grammar.par getHomeGrammar apiTask)
```

The meaning of `par` is all legal interleavings that preserve each child grammar's internal order. If two completions do not depend on each other and do not contend for the same bounded queue/resource, they commute:

```text
getHome.done ; api.done
```

is equivalent to:

```text
api.done ; getHome.done
```

## Refinement

Zoomed out:

```text
Login ; GetPage(session, /home)
```

Zoomed in:

```text
Browser -> Server : HttpGetLogin
Server -> Browser : RedirectToOAuth
Browser -> OAuth  : AuthorizeRequest
OAuth  -> Browser : CallbackCode
Browser -> Server : CallbackCode
Server -> OAuth  : TokenRequest
OAuth  -> Server : TokenResponse
Server -> Browser : SessionIssued
Browser -> Server : HttpGetPage
Server -> Browser : HttpOk
```

An implementation refinement is valid when projecting the detailed trace back to boundary events yields a trace accepted by the parent grammar, and all inherited `Never`, `Always`, `Eventually`, and `Possibly` proof obligations still hold.
