import LeanFM.Session.Calls
import LeanFM.Session.Where
import LeanFM.Session.Types
import Lean.Data.Json

/-!
# Skeletons: each role's typestate as code (clause selfhost.session.skeleton)

`Global.pythonSkeleton` writes one self-contained Python module for a protocol: for every role, a
class per typestate state whose methods are exactly that state's methods. A send method sends and
logs the message, fills in the cause the protocol names, and returns the next state; `receive`
accepts only what the state allows; a state used twice raises. What is left to write by hand is
the decisions: which branch to take, what each message carries, and the transport.

Causes come from the global type: the protocol message a send or receive stands for is found by
its sender, receiver and label. When that is ambiguous (the same sender, receiver and label with
different ids or causes), the method takes the cause as an argument instead of guessing.

Negative requirements: no protocol text other than role and label names reaches the code, and
those only as sanitized identifiers or JSON-escaped string literals (so a name cannot inject code
or end a string or comment); two methods of one state, or two classes, with the same Python name are
an error, not a silent overwrite; an unknown language is an error.
-/

namespace LeanFM.Session

/-- Every interaction of a protocol, in order, including those inside includes and nested sessions. -/
partial def Global.interactions {R : Type} : Global R → List (Interaction R)
  | .msg i k => i :: k.interactions
  | .act _ _ k => k.interactions
  | .choice bs => bs.flatMap (·.interactions)
  | .par bs k | .join _ bs k => bs.flatMap (·.interactions) ++ k.interactions
  | .loop _ b => b.interactions
  | .var _ | .done => []
  | .sessions b k | .box _ b k => b.interactions ++ k.interactions

namespace Skeleton

/-- A Python string literal: JSON's escaping is valid Python. -/
def lit (s : String) : String := (Lean.Json.str s).compress

/-- A Python identifier made of a name's letters, digits and underscores. -/
def ident (s : String) : String :=
  let cs := s.toList.map fun c => if c.isAlphanum || c == '_' then c else '_'
  let t := String.ofList cs
  if t.isEmpty then "_" else if (t.toList.head?.map Char.isDigit).getD false then "_" ++ t else t

/-- `SoldOut` → `sold_out`, for method names. -/
def snake (s : String) : String :=
  let cs := (ident s).toList
  let rec go : List Char → Option Char → List Char
    | [], _ => []
    | c :: rest, prev =>
      let sep := c.isUpper && match prev with
        | some p => p.isLower || p.isDigit
        | none => false
      (if sep then ['_', c.toLower] else [c.toLower]) ++ go rest (some c)
  String.ofList (go cs none)

/-- The protocol message a send or receive stands for: its id and its cause's id, when exactly one
(id, cause) pair has that sender, receiver and label. -/
def lookup (ixs : List (Interaction String)) (src dst label : String) : Option (Option String × Option String) :=
  let found := (ixs.filter fun i => i.src == src && i.dst == dst && i.label == label).map fun i => (i.id, i.cause)
  match found.eraseDups with
  | [p] => some p
  | _ => none

def pyOpt (o : Option String) : String := match o with | some s => lit s | none => "None"

def cls (role : String) (state : String) : String :=
  if state == "End" then "End" else ident role ++ state

def runtime : String := "\
\"\"\"Runtime shared by every role. Generated; do not edit.\"\"\"

from __future__ import annotations

import itertools
from dataclasses import asdict, dataclass, is_dataclass
from typing import List, Optional


class ProtocolError(Exception):
    \"\"\"A step the protocol does not allow here.\"\"\"


def _plain(body):
    \"\"\"A message object as the plain dict that travels and is logged.\"\"\"
    return asdict(body) if is_dataclass(body) and not isinstance(body, type) else body


def _project(body, paths):
    \"\"\"The fields at these dotted paths of a body, nested as in the body; nothing else.\"\"\"
    out = {}
    for path in paths:
        keys = path.split(\".\")
        cur = body
        for key in keys:
            if isinstance(cur, dict) and key in cur:
                cur = cur[key]
            else:
                break
        else:
            node = out
            for key in keys[:-1]:
                node = node.setdefault(key, {})
            node[keys[-1]] = cur
    return out


class Endpoint:
    \"\"\"One role in one session. It numbers events, binds the protocol's message ids to the events
    that were those messages, fills in causes, logs every event, and hands messages to transport.\"\"\"

    def __init__(self, role, session, transport, log=None, new_id=None):
        self.role, self.session = role, str(session)
        self.transport, self.log = transport, log
        counter = itertools.count(1)
        self.new_id = new_id or (lambda: f\"{self.session}.{self.role}.{next(counter)}\")
        self.bind = {}

    def send(self, to, label, pid, cause_pid, body, cause=None):
        body = _plain(body)
        if cause is None and cause_pid is not None:
            cause = self.bind.get(cause_pid)
            if cause is None:
                raise ProtocolError(f\"{label} is caused by {cause_pid}, which has not happened in session {self.session}\")
        event = {\"id\": self.new_id(), \"session\": self.session, \"from\": self.role, \"to\": to, \"label\": label}
        if cause is not None:
            event[\"cause\"] = cause
        if pid is not None:
            self.bind[pid] = event[\"id\"]
        if self.log is not None:
            logged = dict(event)
            reads = READS.get(pid) if pid is not None else None
            if reads:
                # exactly the fields where conditions read; nothing else of the body is logged
                logged[\"fields\"] = _project({} if body is None else body, reads)
            self.log(logged)
        self.transport(dict(event, body={} if body is None else body))
        return event

    def act(self, label):
        event = {\"id\": self.new_id(), \"session\": self.session, \"at\": self.role, \"label\": label, \"act\": True}
        if self.log is not None:
            self.log(dict(event))
        return event

    def accepts(self, msg, src, label):
        return msg.get(\"label\") == label and msg.get(\"from\") == src and msg.get(\"to\") == self.role

    def received(self, msg, pid):
        if str(msg.get(\"session\")) != self.session:
            raise ProtocolError(f\"a message of session {msg.get('session')} reached session {self.session}\")
        if pid is not None:
            self.bind[pid] = msg[\"id\"]

    def refuse(self, state, msg, allowed):
        raise ProtocolError(f\"{self.role} in {state} cannot receive {msg.get('label')} from {msg.get('from')}; \"
                            f\"it accepts {allowed}\")


class State:
    \"\"\"A typestate state. Each is used once: a method consumes it and returns the next state.\"\"\"

    def __init__(self, ep):
        self._ep, self._used = ep, False

    def _take(self):
        if self._used:
            raise ProtocolError(f\"{type(self).__name__} was already used; continue from the state it returned\")
        self._used = True
        return self._ep

    @property
    def endpoint(self):
        return self._ep


class End(State):
    \"\"\"The role has finished this session.\"\"\"


class Fork:
    \"\"\"Concurrent branches: run each state in branches toward End, then join to continue: with the
    End of every branch for par, or of need of them for join (the others keep running beside what
    follows). A role in fewer branches than a join needs waits for all of its own; whether the
    others have ended it cannot see, so session_conform holds the run to the count.\"\"\"

    def __init__(self, branches, then, need=None):
        self.branches, self._then, self._joined = branches, then, False
        self.need = len(branches) if need is None else need

    def join(self, *ends):
        if self._joined:
            raise ProtocolError(\"this fork was already joined\")
        if len(ends) < self.need or len(ends) > len(self.branches) or not all(isinstance(e, End) for e in ends):
            raise ProtocolError(f\"join takes the End of {self.need} of the {len(self.branches)} branches\")
        if len({id(e) for e in ends}) != len(ends):
            raise ProtocolError(\"join was given the same End twice\")
        self._joined = True
        return self._then()


class Server:
    \"\"\"Any number of sessions of the same body, each with its own endpoint.\"\"\"

    def __init__(self, ep, start, then):
        self._ep, self._start, self._then = ep, start, then

    def session(self, session, transport=None, log=None, new_id=None):
        ep = Endpoint(self._ep.role, session, transport or self._ep.transport, log or self._ep.log, new_id)
        return self._start(ep)

    def then(self):
        return self._then(self._ep)
"

open Typestate in
/-- One role's classes. -/
def roleClasses (ixs : List (Interaction String)) (role : String) (l : Local String) (tyName : String → String := fun _ => "") : Except String String := do
  let (start, ms) := l.machine
  -- a role that only serves sessions starts each session in the body's first state
  let served : Option String := match ms.filter (fun m => s!"S{m.1}" == start) with
    | [(_, .serve b "End")] => some b
    | _ => none
  let states := (ms.map (·.1)).eraseDups.filter fun i => served.isNone || nm i != start
  let mut out : List String := []
  for i in states do
    let here := (ms.filter (·.1 == i)).map (·.2)
    let name := cls role (nm i)
    let mut methods : List String := []
    let mut used : List String := []
    let mut lines : List String := []
    let mut docs : List String := []
    let recvs := here.filterMap fun m => match m with
      | .recv fr lb k => some [OfferAlt.recv fr lb k]
      | .offer alts => some alts
      | _ => none
    for m in here do
      match m with
      | .send to lb k =>
        let mn := "send_" ++ snake lb
        if used.contains mn then throw s!"{role}: two methods of {nm i} would both be called {mn}"
        used := mn :: used
        docs := docs ++ [s!"{mn} -> {cls role k}"]
        match lookup ixs role to lb with
        | some (pid, cpid) =>
          let ann := if (tyName lb).isEmpty then "" else s!": Optional[{tyName lb}]"
          lines := lines ++ [s!"    def {mn}(self, body{ann} = None):".replace "body = None" "body=None",
            s!"        ep = self._take()",
            s!"        ep.send({lit to}, {lit lb}, {pyOpt pid}, {pyOpt cpid}, body)",
            s!"        return {if k == "End" then "End" else cls role k}(ep)", ""]
        | none =>
          let ann := if (tyName lb).isEmpty then "" else s!": Optional[{tyName lb}]"
          lines := lines ++ [s!"    def {mn}(self, cause=None, body{ann} = None):".replace "body = None" "body=None",
            s!"        \"\"\"The protocol has more than one message like this: pass the id of the event that caused it, if it names a cause.\"\"\"",
            s!"        ep = self._take()",
            s!"        ep.send({lit to}, {lit lb}, None, None, body, cause=cause)",
            s!"        return {if k == "End" then "End" else cls role k}(ep)", ""]
      | .act lb k =>
        let mn := "do_" ++ snake lb
        if used.contains mn then throw s!"{role}: two methods of {nm i} would both be called {mn}"
        used := mn :: used
        docs := docs ++ [s!"{mn} -> {cls role k}"]
        lines := lines ++ [s!"    def {mn}(self):", s!"        ep = self._take()",
          s!"        ep.act({lit lb})", s!"        return {cls role k}(ep)", ""]
      | .fork subs k need =>
        if used.contains "fork" then throw s!"{role}: {nm i} forks twice"
        used := "fork" :: used
        let any := match need with | some n => s!"any {n} of " | none => ""
        docs := docs ++ [s!"fork -> Fork({any}{", ".intercalate (subs.map (cls role))}) then {cls role k}"]
        let needArg := match need with | some n => s!", need={n}" | none => ""
        lines := lines ++ ["    def fork(self):", "        ep = self._take()",
          s!"        return Fork([{", ".intercalate (subs.map fun s => s!"{cls role s}(ep)")}], lambda: {cls role k}(ep){needArg})", ""]
      | .serve b k =>
        if used.contains "serve" then throw s!"{role}: {nm i} serves twice"
        used := "serve" :: used
        docs := docs ++ [s!"serve -> Server of {cls role b}, then {cls role k}"]
        lines := lines ++ ["    def serve(self):", "        ep = self._take()",
          s!"        return Server(ep, {cls role b}, {cls role k})", ""]
      | .cont k =>
        docs := docs ++ [s!"again -> {cls role k}"]
        if used.contains "again" then throw s!"{role}: {nm i} continues twice"
        used := "again" :: used
        lines := lines ++ ["    def again(self):", s!"        return {cls role k}(self._take())", ""]
      | .stop =>
        if used.contains "stop" then throw s!"{role}: {nm i} stops twice"
        used := "stop" :: used
        docs := docs ++ ["stop -> End"]
        lines := lines ++ ["    def stop(self):", "        return End(self._take())", ""]
      | .recv _ _ _ | .offer _ => pure ()
    let alts := recvs.flatten
    if !alts.isEmpty then
      let allowed := ", ".intercalate (alts.filterMap fun a => match a with
        | .recv fr lb _ => some s!"{lb} from {fr}" | _ => none)
      docs := docs ++ [s!"receive(msg): {allowed}"]
      let mut body : List String := ["    def receive(self, msg):", "        ep = self._ep"]
      for a in alts do
        match a with
        | .recv fr lb k =>
          let pid := (lookup ixs fr role lb).bind (·.1)
          body := body ++ [s!"        if ep.accepts(msg, {lit fr}, {lit lb}):",
            "            self._take()", s!"            ep.received(msg, {pyOpt pid})",
            s!"            return msg, {cls role k}(ep)"]
        | _ => pure ()
      body := body ++ [s!"        ep.refuse({lit name}, msg, {lit allowed})", ""]
      lines := lines ++ body
      for a in alts do
        match a with
        | .nothing =>
          if used.contains "skip" then throw s!"{role}: {nm i} has two empty branches"
          used := "skip" :: used
          docs := docs ++ ["skip -> End (the branch taken did not involve this role)"]
          lines := lines ++ ["    def skip(self):", "        return End(self._take())", ""]
        | .other k =>
          let mn := s!"branch_{ident k}"
          if used.contains mn then throw s!"{role}: two branches of {nm i} enter {k}"
          used := mn :: used
          docs := docs ++ [s!"{mn} -> {cls role k}"]
          lines := lines ++ [s!"    def {mn}(self):", s!"        return {cls role k}(self._take())", ""]
        | .recv .. => pure ()
    methods := (lines.reverse.dropWhile (· == "")).reverse
    let doc := s!"    \"\"\"{ident role} at {nm i}: " ++ "; ".intercalate docs ++ ".\"\"\""
    out := out ++ ["", "", s!"class {name}(State):", doc, ""] ++ methods
  let startCls := cls role (served.getD start)
  let fn := snake role
  let what := if served.isSome then "start state in a new session" else "start state"
  out := out ++ ["", "", s!"def {fn}(session, transport, log=None, new_id=None):",
    s!"    \"\"\"{ident role}'s {what}.\"\"\"",
    s!"    return {startCls}(Endpoint({lit role}, session, transport, log, new_id))"]
  return "\n".intercalate out

end Skeleton

/-- For each message id, the field paths of it that some where condition reads: what the generated
code logs (selfhost.session.where). Conditions outside the condition language read nothing. -/
def Global.conditionReads (g : Global String) : List (String × List String) :=
  let pairs := g.messages.flatMap fun i => match i.guard with
    | some gd => match Where.parse gd.text with | .ok e => e.paths | .error _ => []
    | none => []
  let ids := (pairs.map (·.1)).eraseDups
  ids.map fun x => (x, ((pairs.filter (·.1 == x)).map (·.2) |>.filter (!·.isEmpty)).eraseDups)

/-- The reads as a literal both Python and TypeScript accept: `{"p": ["amount"], "q": ["price"]}`. -/
def readsLiteral (g : Global String) : String :=
  "{" ++ ", ".intercalate (g.conditionReads.map fun (x, fs) =>
    Skeleton.lit x ++ ": [" ++ ", ".intercalate (fs.map Skeleton.lit) ++ "]") ++ "}"

/-- The names of the classes a module defines (`class Name` at the start of a line). -/
def classNames (code : String) : List String :=
  (code.splitOn "\n").filterMap fun line =>
    if line.startsWith "class " || line.startsWith "export class " || line.startsWith "export interface " || line.startsWith "export type " then
      let rest := (line.splitOn " ").filter (· != "") |>.dropWhile (fun w => ["export", "class", "interface", "type"].contains w)
      rest.head?.map fun w => String.ofList (w.toList.takeWhile fun c => c.isAlphanum || c == '_')
    else none

def pyType : Types.Ty → String
  | .nat | .int => "int" | .str => "str" | .bool => "bool"
  | .msg n => Types.protoName n
  | .list t => s!"List[{pyType t}]"
  | .opt t => s!"Optional[{pyType t}]"

/-- A message type as a dataclass. -/
def pyMessage (m : Types.Message) : String :=
  let doc := if m.doc.isEmpty then [] else [s!"    \"\"\"{m.doc}\"\"\""]
  let body := if m.fields.isEmpty && doc.isEmpty then ["    pass"]
    else doc ++ m.fields.map fun f => s!"    {f.name}: {pyType f.ty}"
  "\n".intercalate (["@dataclass", s!"class {Types.protoName m.name}:"] ++ body)

open Skeleton in
/-- The protocol as a Python module: the runtime, then every role's states as classes. -/
def Global.pythonSkeleton (g : Global String) (name : String) (roles : List String) (types : Types.Env := []) : Except String String := do
  let ixs := g.interactions
  let labels := (g.messages.map (·.label)).eraseDups
  let ms ← Types.complete types labels
  let names := roles.map ident
  if names.eraseDups.length != names.length then throw "two roles have the same Python name"
  let mut parts : List String := []
  for r in roles do
    let l ← match g.project r with
      | .ok l => pure l
      | .error e => throw s!"{r} has no projection: {e}"
    parts := parts ++ [← roleClasses ixs r l Types.protoName]
  let header := s!"\"\"\"Generated by LeanFM from protocol {ident name}; regenerate it with session_skeleton rather than editing.

Each role's states are classes; a method consumes its state and returns the next. The start
functions are {", ".intercalate (roles.map snake)}. A transport is a function that takes a message
(the logged event plus a body) and delivers it; log, if given, receives every event for
session_conform.
\"\"\"
"
  -- the runtime's own docstring is replaced by the module's
  let rt := (runtime.splitOn "\n").drop 1
  let reads := s!"# The fields of each message that where conditions read: logged, nothing else of a body.\nREADS = {readsLiteral g}\n\n\n"
  let taken := classNames ("\n".intercalate (rt ++ parts))
  for m in ms do
    if taken.contains (Types.protoName m.name) then throw s!"message type {m.name} has the same Python name as a class of the module; rename the message"
  let msgs := "# The message types (selfhost.session.types): send methods take these, sent as plain dicts.\n\n" ++
    "\n\n".intercalate (ms.map pyMessage) ++ "\n\n\n"
  return header ++ "\n".intercalate rt ++ msgs ++ reads ++ "\n".intercalate parts ++ "\n"

end LeanFM.Session
