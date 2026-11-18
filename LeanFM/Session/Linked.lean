import LeanFM.Session.Conform

/-!
# Linked logs: every prev and cause names an event that exists

A log as it arrives is a `List LogEvent`, and any `prev` or `cause` in it may name an event that is
not there. A `Linked` log is one whose links all resolve. Its constructor is private: the only ways
to make one are `Linked.empty`, `Linked.push` (which takes a proof that the new event's links name
events already in the log) and `Linked.check` (which decides it for a list). So code that holds a
`Linked` never meets a dangling link, and `Linked.prev` and `Linked.cause` return the event itself,
not an `Option`: the lookup cannot fail, and Lean checks that it cannot.

`session_conform` turns a log into a `Linked` before it replays anything; a log that is not linked
is reported with every dangling link and not replayed.

Negative requirements: a `Linked` is never made from a list with a dangling link; a dangling link is
never ignored or reported as some other fault.
-/

namespace LeanFM.Session

/-- The events an event names: its prev and its cause. -/
def LogEvent.links (e : LogEvent) : List String := [e.prev, e.cause].filterMap fun x => x

/-- Every link of every event names an event of the list. -/
def Resolved (evs : List LogEvent) : Prop :=
  ∀ e ∈ evs, ∀ p ∈ e.links, ∃ t ∈ evs, t.id = p

instance (evs : List LogEvent) : Decidable (Resolved evs) := by
  unfold Resolved; infer_instance

structure Linked where
  private mk ::
  events : List LogEvent
  resolved : Resolved events

namespace Linked

def empty : Linked := ⟨[], by simp [Resolved]⟩

/-- A log with one more event at the end, given that its links name events already in the log. -/
def push (l : Linked) (e : LogEvent) (h : ∀ p ∈ e.links, ∃ t ∈ l.events, t.id = p) : Linked :=
  ⟨l.events ++ [e], by
    intro x hx p hp
    rcases List.mem_append.1 hx with hx | hx
    · obtain ⟨t, ht, rfl⟩ := l.resolved x hx p hp
      exact ⟨t, List.mem_append_left _ ht, rfl⟩
    · rw [List.mem_singleton.1 hx] at hp
      obtain ⟨t, ht, rfl⟩ := h p hp
      exact ⟨t, List.mem_append_left _ ht, rfl⟩⟩

theorem push_events (l : Linked) (e : LogEvent) (h) : (l.push e h).events = l.events ++ [e] := rfl

/-- Every dangling link of a list, as `(event, "prev" or "cause", the id it names)`. -/
def dangling (evs : List LogEvent) : List (String × String × String) :=
  let ids := evs.map (·.id)
  evs.flatMap fun e =>
    [("prev", e.prev), ("cause", e.cause)].filterMap fun (what, l) => match l with
      | some p => if ids.contains p then none else some (e.id, what, p)
      | none => none

/-- The list as a linked log, or every dangling link in it. -/
def check (evs : List LogEvent) : Except (List String) Linked :=
  if h : Resolved evs then .ok ⟨evs, h⟩
  else .error ((dangling evs).map fun (e, what, p) => s!"event {e}: {what} {p} is not an event of the log")

theorem check_events {evs : List LogEvent} {l : Linked} (h : check evs = .ok l) : l.events = evs := by
  unfold check at h
  split at h
  · cases h; rfl
  · cases h

/-- The event a link names. Total: the log is linked, so it is there. -/
def target (l : Linked) {e : LogEvent} (he : e ∈ l.events) {p : String} (hp : p ∈ e.links) : LogEvent :=
  (l.events.find? (·.id == p)).get (by
    obtain ⟨t, ht, htp⟩ := l.resolved e he p hp
    exact List.find?_isSome.2 ⟨t, ht, by simp [htp]⟩)

theorem target_find (l : Linked) {e : LogEvent} (he : e ∈ l.events) {p : String} (hp : p ∈ e.links) :
    l.events.find? (·.id == p) = some (l.target he hp) := by
  simp only [target, Option.some_get]

theorem target_id (l : Linked) {e : LogEvent} (he : e ∈ l.events) {p : String} (hp : p ∈ e.links) :
    (l.target he hp).id = p := by
  simpa using List.find?_some (target_find l he hp)

theorem target_mem (l : Linked) {e : LogEvent} (he : e ∈ l.events) {p : String} (hp : p ∈ e.links) :
    l.target he hp ∈ l.events :=
  List.mem_of_find?_eq_some (target_find l he hp)

theorem prev_mem_links {e : LogEvent} {p : String} (h : e.prev = some p) : p ∈ e.links := by
  simp [LogEvent.links, h]

theorem cause_mem_links {e : LogEvent} {c : String} (h : e.cause = some c) : c ∈ e.links := by
  cases hp : e.prev <;> simp [LogEvent.links, hp, h]

/-- The previous event of an event's sender: an event, never a missing one. -/
def prev (l : Linked) {e : LogEvent} (he : e ∈ l.events) {p : String} (h : e.prev = some p) : LogEvent :=
  l.target he (prev_mem_links h)

/-- The event that caused an event: an event, never a missing one. -/
def cause (l : Linked) {e : LogEvent} (he : e ∈ l.events) {c : String} (h : e.cause = some c) : LogEvent :=
  l.target he (cause_mem_links h)

theorem cause_id (l : Linked) {e : LogEvent} (he : e ∈ l.events) {c : String} (h : e.cause = some c) :
    (l.cause he h).id = c := target_id l he _

end Linked

/-- A response in a linked log, with the request it answers: the response's cause is the request,
and it goes back the way the request came. Built only by `Answered.of?`, so holding one is the proof. -/
structure Answered (l : Linked) where
  private mk ::
  response : LogEvent
  request : LogEvent
  inLog : response ∈ l.events ∧ request ∈ l.events
  answers : response.cause = some request.id
  reversed : response.src = request.dst ∧ response.dst = request.src

/-- The response with the request it answers, when its cause is a request from its receiver to its
sender; `none` otherwise. -/
def Answered.of? (l : Linked) (r : LogEvent) (hr : r ∈ l.events) : Option (Answered l) :=
  match hc : r.cause with
  | none => none
  | some c =>
    let q := l.cause hr hc
    if hrev : r.src = q.dst ∧ r.dst = q.src then
      some ⟨r, q, ⟨hr, Linked.target_mem l hr _⟩, by rw [hc, Linked.cause_id l hr hc], hrev⟩
    else none

end LeanFM.Session
