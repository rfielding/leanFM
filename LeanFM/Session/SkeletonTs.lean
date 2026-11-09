import LeanFM.Session.Skeleton

/-!
# TypeScript skeletons (clause selfhost.session.skeleton)

`Global.typescriptSkeleton` writes the same typestate classes as `Global.pythonSkeleton`, as one
self-contained TypeScript module, so the compiler enforces what Python checks at run time: a state's
methods are exactly what the protocol allows there, named as in the typestate API (`sendLent`), so
calling anything else does not type-check. `receive` returns a union tagged by label, and switching on
`r.label` narrows `r.next` to the state that message leads to. Each state class carries a literal
`state` field, so two states with the same methods are still different types. Using a state twice is
not a type error (TypeScript has no linear types), so it raises at run time, as in Python.

Negative requirements: as for Python, names reach the code only as identifiers and JSON-escaped
string literals (valid in TypeScript), colliding method or class names are an error, and causes the
global type leaves ambiguous are passed, not guessed.
-/

namespace LeanFM.Session
namespace Skeleton

/-- `SoldOut` → `SoldOut`, `sold_out` → `Sold_out`: the label as the tail of a method name. -/
def tail (s : String) : String :=
  match (ident s).toList with
  | c :: cs => String.ofList (c.toUpper :: cs)
  | [] => "_"

def tsRuntime : String := "\
// Runtime shared by every role.

export class ProtocolError extends Error {}

/** A message as it travels: the logged event plus a body. */
export interface Message {
  id: string; session: string; from: string; to: string; label: string; cause?: string; body?: unknown;
}
export interface ActEvent { id: string; session: string; at: string; label: string; act: true }
/** What session_conform reads: one per message sent or event performed. */
export type LogEvent = Omit<Message, \"body\"> | ActEvent;
export type Transport = (m: Message) => void;
export type Log = (e: LogEvent) => void;

/** One role in one session. It numbers events, binds the protocol's message ids to the events that
 * were those messages, fills in causes, logs every event, and hands messages to the transport. */
export class Endpoint {
  readonly bind = new Map<string, string>();
  readonly newId: () => string;
  private n = 0;

  constructor(readonly role: string, readonly session: string, readonly transport: Transport,
              readonly log?: Log, newId?: () => string) {
    this.newId = newId ?? (() => `${this.session}.${this.role}.${++this.n}`);
  }

  send(to: string, label: string, pid: string | null, causePid: string | null, body: unknown,
       cause?: string): Message {
    if (cause === undefined && causePid !== null) {
      cause = this.bind.get(causePid);
      if (cause === undefined) {
        throw new ProtocolError(`${label} is caused by ${causePid}, which has not happened in session ${this.session}`);
      }
    }
    const event: Omit<Message, \"body\"> = { id: this.newId(), session: this.session, from: this.role, to, label };
    if (cause !== undefined) event.cause = cause;
    if (pid !== null) this.bind.set(pid, event.id);
    this.log?.({ ...event });
    const message: Message = { ...event, body: body ?? {} };
    this.transport(message);
    return message;
  }

  act(label: string): ActEvent {
    const event: ActEvent = { id: this.newId(), session: this.session, at: this.role, label, act: true };
    this.log?.({ ...event });
    return event;
  }

  accepts(msg: Message, src: string, label: string): boolean {
    return msg.label === label && msg.from === src && msg.to === this.role;
  }

  received(msg: Message, pid: string | null): void {
    if (String(msg.session) !== this.session) {
      throw new ProtocolError(`a message of session ${msg.session} reached session ${this.session}`);
    }
    if (pid !== null) this.bind.set(pid, msg.id);
  }

  refuse(state: string, msg: Message, allowed: string): never {
    throw new ProtocolError(`${this.role} in ${state} cannot receive ${msg.label} from ${msg.from}; it accepts ${allowed}`);
  }
}

/** A typestate state. Each is used once: a method consumes it and returns the next state. */
export abstract class State {
  private used = false;
  constructor(protected readonly ep: Endpoint) {}

  protected take(): Endpoint {
    if (this.used) {
      throw new ProtocolError(`${this.constructor.name} was already used; continue from the state it returned`);
    }
    this.used = true;
    return this.ep;
  }

  get endpoint(): Endpoint { return this.ep; }
}

/** The role has finished this session. */
export class End extends State { readonly state = \"End\" as const; }

/** Concurrent branches: run each toward End, then join with the End of every branch for par, or of
 * need of them for join (the others keep running beside what follows). */
export class Fork<B extends State[], T extends State> {
  private joined = false;
  readonly need: number;
  constructor(readonly branches: B, private readonly then: () => T, need?: number) {
    this.need = need ?? branches.length;
  }

  join(...ends: End[]): T {
    if (this.joined) throw new ProtocolError(\"this fork was already joined\");
    if (ends.length < this.need || ends.length > this.branches.length || new Set(ends).size !== ends.length) {
      throw new ProtocolError(`join takes the End of ${this.need} of the ${this.branches.length} branches`);
    }
    this.joined = true;
    return this.then();
  }
}

/** Any number of sessions of the same body, each with its own endpoint. */
export class Server<S extends State, T extends State> {
  constructor(private readonly ep: Endpoint, private readonly start: (ep: Endpoint) => S,
              private readonly after: (ep: Endpoint) => T) {}

  session(session: string, transport?: Transport, log?: Log, newId?: () => string): S {
    return this.start(new Endpoint(this.ep.role, session, transport ?? this.ep.transport, log ?? this.ep.log, newId));
  }

  then(): T { return this.after(this.ep); }
}
"

open Typestate in
/-- One role's classes, in TypeScript. -/
def roleClassesTs (ixs : List (Interaction String)) (role : String) (l : Local String) : Except String String := do
  let (start, ms) := l.machine
  let served : Option String := match ms.filter (fun m => s!"S{m.1}" == start) with
    | [(_, .serve b "End")] => some b
    | _ => none
  let states := (ms.map (·.1)).eraseDups.filter fun i => served.isNone || nm i != start
  let new (k : String) (ep : String) : String := s!"new {cls role k}({ep})"
  let mut out : List String := []
  for i in states do
    let here := (ms.filter (·.1 == i)).map (·.2)
    let name := cls role (nm i)
    let mut used : List String := []
    let mut lines : List String := []
    let mut docs : List String := []
    for m in here do
      match m with
      | .send to lb k =>
        let mn := "send" ++ tail lb
        if used.contains mn then throw s!"{role}: two methods of {nm i} would both be called {mn}"
        used := mn :: used
        docs := docs ++ [s!"{mn} → {cls role k}"]
        match lookup ixs role to lb with
        | some (pid, cpid) =>
          lines := lines ++ [s!"  {mn}(body?: unknown): {cls role k} \{",
            s!"    const ep = this.take();",
            s!"    ep.send({lit to}, {lit lb}, {pyOptTs pid}, {pyOptTs cpid}, body);",
            s!"    return {new k "ep"};", "  }", ""]
        | none =>
          lines := lines ++ [s!"  /** The protocol has more than one message like this: pass the id of the event that caused it, if it names a cause. */",
            s!"  {mn}(cause?: string, body?: unknown): {cls role k} \{",
            s!"    const ep = this.take();",
            s!"    ep.send({lit to}, {lit lb}, null, null, body, cause);",
            s!"    return {new k "ep"};", "  }", ""]
      | .act lb k =>
        let mn := "do" ++ tail lb
        if used.contains mn then throw s!"{role}: two methods of {nm i} would both be called {mn}"
        used := mn :: used
        docs := docs ++ [s!"{mn} → {cls role k}"]
        lines := lines ++ [s!"  {mn}(): {cls role k} \{", "    const ep = this.take();",
          s!"    ep.act({lit lb});", s!"    return {new k "ep"};", "  }", ""]
      | .fork subs k need =>
        if used.contains "fork" then throw s!"{role}: {nm i} forks twice"
        used := "fork" :: used
        let any := match need with | some n => s!"any {n} of " | none => ""
        docs := docs ++ [s!"fork → Fork({any}{", ".intercalate (subs.map (cls role))}) then {cls role k}"]
        let ty := s!"Fork<[{", ".intercalate (subs.map (cls role))}], {cls role k}>"
        let needArg := match need with | some n => s!", {n}" | none => ""
        lines := lines ++ [s!"  fork(): {ty} \{", "    const ep = this.take();",
          s!"    return new Fork([{", ".intercalate (subs.map fun s => new s "ep")}] as [{", ".intercalate (subs.map (cls role))}], () => {new k "ep"}{needArg});", "  }", ""]
      | .serve b k =>
        if used.contains "serve" then throw s!"{role}: {nm i} serves twice"
        used := "serve" :: used
        docs := docs ++ [s!"serve → Server of {cls role b}, then {cls role k}"]
        lines := lines ++ [s!"  serve(): Server<{cls role b}, {cls role k}> \{", "    const ep = this.take();",
          s!"    return new Server(ep, (e) => {new b "e"}, (e) => {new k "e"});", "  }", ""]
      | .cont k =>
        if used.contains "again" then throw s!"{role}: {nm i} continues twice"
        used := "again" :: used
        docs := docs ++ [s!"again → {cls role k}"]
        lines := lines ++ [s!"  again(): {cls role k} \{ return {new k "this.take()"}; }", ""]
      | .stop =>
        if used.contains "stop" then throw s!"{role}: {nm i} stops twice"
        used := "stop" :: used
        docs := docs ++ ["stop → End"]
        lines := lines ++ ["  stop(): End { return new End(this.take()); }", ""]
      | .recv _ _ _ | .offer _ => pure ()
    let alts := (here.filterMap fun m => match m with
      | .recv fr lb k => some [OfferAlt.recv fr lb k]
      | .offer alts => some alts
      | _ => none).flatten
    let recvs := alts.filterMap fun a => match a with | .recv fr lb k => some (fr, lb, k) | _ => none
    if !recvs.isEmpty then
      let allowed := ", ".intercalate (recvs.map fun (fr, lb, _) => s!"{lb} from {fr}")
      docs := docs ++ [s!"receive(msg): {allowed}"]
      let union := " | ".intercalate (recvs.map fun (_, lb, k) => s!"\{ label: {lit lb}; msg: Message; next: {cls role k} }")
      let mut body : List String := [s!"  receive(msg: Message): {union} \{", "    const ep = this.ep;"]
      for (fr, lb, k) in recvs do
        let pid := (lookup ixs fr role lb).bind (·.1)
        body := body ++ [s!"    if (ep.accepts(msg, {lit fr}, {lit lb})) \{",
          "      this.take();", s!"      ep.received(msg, {pyOptTs pid});",
          s!"      return \{ label: {lit lb}, msg, next: {new k "ep"} };", "    }"]
      body := body ++ [s!"    return ep.refuse({lit name}, msg, {lit allowed});", "  }", ""]
      lines := lines ++ body
    for a in alts do
      match a with
      | .nothing =>
        if used.contains "skip" then throw s!"{role}: {nm i} has two empty branches"
        used := "skip" :: used
        docs := docs ++ ["skip → End (the branch taken did not involve this role)"]
        lines := lines ++ ["  skip(): End { return new End(this.take()); }", ""]
      | .other k =>
        let mn := s!"branch{ident k}"
        if used.contains mn then throw s!"{role}: two branches of {nm i} enter {k}"
        used := mn :: used
        docs := docs ++ [s!"{mn} → {cls role k}"]
        lines := lines ++ [s!"  {mn}(): {cls role k} \{ return {new k "this.take()"}; }", ""]
      | .recv .. => pure ()
    let methods := (lines.reverse.dropWhile (· == "")).reverse
    out := out ++ ["", s!"/** {ident role} at {nm i}: " ++ "; ".intercalate docs ++ ". */",
      s!"export class {name} extends State \{", s!"  readonly state = {lit name} as const;", ""] ++ methods ++ ["}"]
  let startCls := cls role (served.getD start)
  let what := if served.isSome then "start state in a new session" else "start state"
  out := out ++ ["", s!"/** {ident role}'s {what}. */",
    s!"export function {snake role}(session: string, transport: Transport, log?: Log, newId?: () => string): {startCls} \{",
    s!"  return new {startCls}(new Endpoint({lit role}, session, transport, log, newId));", "}"]
  return "\n".intercalate out
where
  pyOptTs (o : Option String) : String := match o with | some s => lit s | none => "null"

end Skeleton

open Skeleton in
/-- The protocol as a TypeScript module: the runtime, then every role's states as classes. -/
def Global.typescriptSkeleton (g : Global String) (name : String) (roles : List String) : Except String String := do
  let ixs := g.interactions
  let names := roles.map ident
  if names.eraseDups.length != names.length then throw "two roles have the same TypeScript name"
  let mut parts : List String := []
  for r in roles do
    let l ← match g.project r with
      | .ok l => pure l
      | .error e => throw s!"{r} has no projection: {e}"
    parts := parts ++ [← roleClassesTs ixs r l]
  let header := s!"// Generated by LeanFM from protocol {ident name}; regenerate it with session_skeleton rather than editing.
//
// Each role's states are classes whose methods are exactly what the protocol allows there, so a
// step it does not allow does not type-check; a method consumes its state and returns the next.
// The start functions are {", ".intercalate (roles.map snake)}. A transport delivers a message (the
// logged event plus a body); log, if given, receives every event for session_conform.

"
  return header ++ tsRuntime ++ "\n".intercalate parts ++ "\n"

end LeanFM.Session
