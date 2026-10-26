import LeanFM.Artifacts
import LeanFM.MDPDiagram

/-!
# A legal example: knowledge, obligation, permission, lawful and right

A fictional statute (the *Model Tenancy Deposit Act*) and a separately declared
moral code are evaluated over four admissible histories of one tenancy. The
example keeps three meanings of "legal" apart:

* **admissible** – allowed by the protocol grammar (LeanFM's `A`/`E` range over these);
* **lawful / unlawful** – judged against the declared statute's ideal futures (`O^Act`, `P^Act`);
* **right / wrong** – judged against a declared moral code with a named author (`O^Code`, `P^Code`).

Knowledge is possession knowledge computed from each actor's causal past
(`prevIds` and `causeIds`), so an obligation can be conditioned on what an actor
knew. The statute and the moral code are invented for illustration; this is not
legal advice and not a claim about any real jurisdiction.

Run: `lake env lean --run LegalDepositExample.lean` (writes `book/generated/legal-*`).
-/

open LeanFM

namespace LegalDepositExample

structure Ev where
  id : String
  day : Nat
  src : String
  dst : String
  msg : String
  detail : String := ""
  prev : List String := []
  cause : List String := []
deriving Repr, BEq, Inhabited

structure History where
  key : String
  title : String
  events : List Ev

def find? (h : History) (id : String) : Option Ev := h.events.find? (·.id == id)

/-- Causal ancestry: everything reachable through prevIds and causeIds (strictly before `id`). -/
partial def ancestors (h : History) (id : String) : List String :=
  let rec go (todo seen : List String) : List String :=
    match todo with
    | [] => seen
    | x :: rest =>
      match find? h x with
      | none => go rest seen
      | some e =>
        let next := (e.prev ++ e.cause).filter (fun p => !seen.contains p)
        go (rest ++ next) (seen ++ next)
  go [id] []

/-- Did `actor` receive a message named `msg` in the causal past of event `id`, or at it? -/
def received (h : History) (actor msg id : String) : Bool :=
  (id :: ancestors h id).any fun a =>
    match find? h a with
    | some e => e.dst == actor && e.msg == msg
    | none => false

/-- Possession knowledge: the landlord knows the forwarding address at the first event
    whose causal past contains its delivery to the landlord. -/
def knowsAddressFrom (h : History) : Option Nat :=
  (h.events.filter fun e => received h "Landlord" "ForwardingAddress" e.id).map (·.day) |>.min?

def firstDay (h : History) (msg : String) : Option Nat :=
  (h.events.filter (·.msg == msg)).map (·.day) |>.min?

def has (h : History) (msg : String) : Bool := h.events.any (·.msg == msg)

inductive Status
  | notTriggered | pending | fulfilled | violated | repaired
deriving BEq, Repr

def Status.text : Status → String
  | .notTriggered => "not triggered"
  | .pending => "pending"
  | .fulfilled => "fulfilled"
  | .violated => "violated"
  | .repaired => "violated, then repaired"

/-- Evaluation horizon: the last observed day. -/
def horizon (h : History) : Nat := (h.events.map (·.day)).max?.getD 0

/-- Act §1: protect the deposit within 30 days of payment. O^Act_L F≤30 protected. -/
def act1 (h : History) : Status :=
  match firstDay h "DepositPaid" with
  | none => .notTriggered
  | some paid =>
    match firstDay h "DepositProtected" with
    | some d => if d ≤ paid + 30 then .fulfilled else .violated
    | none => if horizon h ≤ paid + 30 then .pending else .violated

/-- Act §2: once the lease has ended AND the landlord knows the forwarding address,
    return the deposit or itemise deductions within 14 days. The trigger is knowledge,
    computed from the landlord's causal past, not the tenant's sending. -/
def act2 (h : History) : Status :=
  match firstDay h "LeaseEnded", knowsAddressFrom h with
  | some ended, some known =>
    let start := max ended known
    match firstDay h "DepositReturned" with
    | some d => if d ≤ start + 14 then .fulfilled
                else if has h "PenaltyPaid" then .repaired else .violated
    | none => if horizon h ≤ start + 14 then .pending
              else if has h "PenaltyPaid" then .repaired else .violated
  | _, _ => .notTriggered

/-- Act §3 (contrary-to-duty): if §2 is violated, pay the deposit plus an equal penalty.
    This obligation exists only on sub-ideal histories, where §2 has already failed. -/
def act3 (h : History) : Status :=
  match act2 h with
  | .violated => .violated
  | .repaired => .fulfilled
  | _ => .notTriggered

/-- Act §4: the deposit must never be applied to rent. F^Act (offset) = O^Act G ¬offset. -/
def act4 (h : History) : Status := if has h "RentOffsetAgreed" then .violated else .fulfilled

/-- Code (declared by the stakeholder): (a) never charge for normal wear and tear;
    (b) a landlord who knows another way to reach the tenant makes a reasonable effort;
    (c) help a tenant in documented hardship when it costs you nothing you are owed. -/
def codeA (h : History) : Status :=
  if h.events.any (fun e => e.msg == "DeductionsItemized" && e.detail.startsWith "normal wear") then .violated
  else if has h "DeductionsItemized" then .fulfilled else .notTriggered

def codeB (h : History) : Status :=
  -- The landlord holds the tenant's email from the lease (e1 is in every causal past), so
  -- when the statute's trigger never fires the code still asks for a reasonable effort.
  if knowsAddressFrom h == none && has h "LeaseSigned" && has h "LeaseEnded" then
    (if has h "ContactAttempt" then .fulfilled else .violated)
  else .notTriggered

def codeC (h : History) : Status :=
  if has h "HardshipRequest" then (if has h "RentOffsetAgreed" then .fulfilled else .violated) else .notTriggered

def lawful (h : History) : Bool :=
  [act1 h, act2 h, act3 h, act4 h].all fun s => s != .violated

def right (h : History) : Bool := [codeA h, codeB h, codeC h].all fun s => s != .violated

def repaired (h : History) : Bool := [act1 h, act2 h, act3 h, act4 h].any (· == .repaired)

def underAct (h : History) : String :=
  if !lawful h then "unlawful" else if repaired h then "violated, then repaired" else "lawful"

def underCode (h : History) : String :=
  let st := [codeA h, codeB h, codeC h]
  if st.any (· == .violated) then "wrong" else if st.any (· == .fulfilled) then "right" else "no duty arose"

def verdict (h : History) : String := underAct h ++ " / " ++ underCode h

/-- A normative conflict: one code requires what the other forbids for the same actor. -/
def conflict (h : History) : String :=
  if has h "HardshipRequest" then
    "$O^{Act}_L\\,G\\,\\neg\\mathit{offset}$ (Act \\S4) and $O^{Code}_L\\,F\\,\\mathit{offset}$ (Code c): no future is ideal under both"
  else "none"

-- ---------- the four admissible histories ----------
def lease : List Ev :=
  [ {id := "e1", day := 0, src := "Landlord", dst := "Tenant", msg := "LeaseSigned", detail := "rent 1000, deposit 1000, tenant email on file"}
  , {id := "e2", day := 1, src := "Tenant", dst := "Landlord", msg := "DepositPaid", detail := "1000", prev := ["e1"], cause := ["e1"]}
  , {id := "e3", day := 12, src := "Landlord", dst := "Registry", msg := "DepositProtected", detail := "scheme ref 7731", prev := ["e2"], cause := ["e2"]}
  , {id := "e4", day := 365, src := "Tenant", dst := "Landlord", msg := "LeaseEnded", detail := "keys returned", prev := ["e2"]} ]

def compliant : History :=
  { key := "compliant", title := "Itemised deduction on time"
  , events := lease ++
    [ {id := "e5", day := 366, src := "Tenant", dst := "Landlord", msg := "ForwardingAddress", detail := "12 Elm St", prev := ["e4"]}
    , {id := "e6", day := 372, src := "Landlord", dst := "Tenant", msg := "DeductionsItemized", detail := "normal wear: repaint, 150", prev := ["e5", "e3"], cause := ["e5"]}
    , {id := "e7", day := 372, src := "Landlord", dst := "Tenant", msg := "DepositReturned", detail := "850", prev := ["e6"], cause := ["e5"]} ] }

def late : History :=
  { key := "late", title := "Returned late, penalty paid"
  , events := lease ++
    [ {id := "e5", day := 366, src := "Tenant", dst := "Landlord", msg := "ForwardingAddress", detail := "12 Elm St", prev := ["e4"]}
    , {id := "e6", day := 391, src := "Landlord", dst := "Tenant", msg := "DepositReturned", detail := "1000", prev := ["e5", "e3"], cause := ["e5"]}
    , {id := "e7", day := 395, src := "Tenant", dst := "Court", msg := "ClaimFiled", detail := "Act s2 deadline day 380 missed", prev := ["e6"], cause := ["e6"]}
    , {id := "e8", day := 410, src := "Court", dst := "Landlord", msg := "Judgment", detail := "pay penalty 1000 under s3", prev := ["e7"], cause := ["e7"]}
    , {id := "e9", day := 420, src := "Landlord", dst := "Tenant", msg := "PenaltyPaid", detail := "1000", prev := ["e8"], cause := ["e8"]} ] }

def lost : History :=
  { key := "lost", title := "Address lost in the post"
  , events := lease ++
    [ {id := "e5", day := 366, src := "Tenant", dst := "Post", msg := "AddressPosted", detail := "letter to landlord", prev := ["e4"]}
    , {id := "e6", day := 400, src := "Tenant", dst := "Tenant", msg := "BelievesViolated", detail := "no refund after 34 days", prev := ["e5"]} ] }

def mercy : History :=
  { key := "mercy", title := "Hardship: deposit used as last rent"
  , events := lease ++
    [ {id := "e5", day := 330, src := "Tenant", dst := "Landlord", msg := "HardshipRequest", detail := "job lost; use deposit for final rent", prev := ["e2"]}
    , {id := "e6", day := 332, src := "Landlord", dst := "Tenant", msg := "RentOffsetAgreed", detail := "deposit applied to month 12 rent", prev := ["e5", "e3"], cause := ["e5"]}
    , {id := "e7", day := 366, src := "Tenant", dst := "Landlord", msg := "ForwardingAddress", detail := "12 Elm St", prev := ["e4", "e6"]}
    , {id := "e8", day := 366, src := "Landlord", dst := "Tenant", msg := "DepositReturned", detail := "0 (already applied to rent)", prev := ["e7"], cause := ["e7"]} ] }

def histories : List History := [compliant, late, lost, mercy]

-- ---------- generated book material ----------
def tex (s : String) : String :=
  (((s.replace "_" "\\_").replace "&" "\\&").replace "%" "\\%").replace "#" "\\#"

def statusTable : String :=
  "% Generated by LegalDepositExample.lean; do not edit.\n" ++
  "\\begin{tabular}{@{}llllllll@{}}\\toprule\n" ++
  "History & Act \\S1 & Act \\S2 & Act \\S3 (CTD) & Act \\S4 & Code (a) & Code (b) & Code (c)\\\\\\midrule\n" ++
  String.join (histories.map fun h =>
    tex h.title ++ " & " ++ (act1 h).text ++ " & " ++ (act2 h).text ++ " & " ++ (act3 h).text ++ " & " ++ (act4 h).text ++
    " & " ++ (codeA h).text ++ " & " ++ (codeB h).text ++ " & " ++ (codeC h).text ++ "\\\\\n") ++
  "\\bottomrule\\end{tabular}\n"

def verdictTable : String :=
  "% Generated by LegalDepositExample.lean; do not edit.\n" ++
  "\\begin{tabular}{@{}p{0.2\\textwidth}p{0.14\\textwidth}p{0.1\\textwidth}p{0.12\\textwidth}p{0.34\\textwidth}@{}}\\toprule\n" ++
  "History & Under the Act & Under the Code & Landlord knows address from & Normative conflict\\\\\\midrule\n" ++
  String.join (histories.map fun h =>
    tex h.title ++ " & " ++ underAct h ++ " & " ++ underCode h ++ " & " ++ (match knowsAddressFrom h with | some d => "day " ++ toString d | none => "never") ++
    " & " ++ conflict h ++ "\\\\\n") ++
  "\\bottomrule\\end{tabular}\n"

def eventTable (h : History) : String :=
  "% Generated by LegalDepositExample.lean; do not edit.\n" ++
  "\\begin{tabular}{@{}rrllp{0.3\\textwidth}ll@{}}\\toprule\n" ++
  "Id & Day & From $\\to$ To & Message & Detail & prevIds & causeIds\\\\\\midrule\n" ++
  String.join (h.events.map fun e =>
    e.id ++ " & " ++ toString e.day ++ " & " ++ e.src ++ " $\\to$ " ++ e.dst ++ " & \\texttt{" ++ e.msg ++ "} & " ++ tex e.detail ++
    " & " ++ ", ".intercalate e.prev ++ " & " ++ ", ".intercalate e.cause ++ "\\\\\n") ++
  "\\bottomrule\\end{tabular}\n"

def interaction (h : History) : String :=
  let actors := ["Tenant", "Landlord", "Registry", "Court", "Post"].filter fun a => h.events.any fun e => e.src == a || e.dst == a
  MDPDiagram.renderInteractionTeX actors (h.events.filter (fun e => e.src != e.dst) |>.map fun e =>
    { src := e.src, dst := e.dst, label := e.id ++ " day " ++ toString e.day ++ ": " ++ e.msg })

def provenance : DesiredOutput :=
  { id := "legal.deposit.verdicts"
  , prompt := "Make a legal example, and put it into the book; use it to deal with modalities regarding right and wrong, legal and illegal."
  , question := "For each admissible history, which statute and moral-code obligations are fulfilled, violated or repaired, and is the history lawful and right?"
  , kind := .scalar
  , eventSource := "LegalDepositExample.histories: ScenarioEvent-style events with prevIds and causeIds"
  , reducer := "possession knowledge from causal ancestry; deadline obligations from knowledge-triggered starts; contrary-to-duty reparation; per-code verdicts and conflicts"
  , unit := "status per norm per history" }

def main : IO Unit := do
  IO.FS.createDirAll "book/generated"
  IO.FS.writeFile "book/generated/legal-status.tex" statusTable
  IO.FS.writeFile "book/generated/legal-verdicts.tex" verdictTable
  IO.FS.writeFile "book/generated/legal-late-events.tex" (eventTable late)
  IO.FS.writeFile "book/generated/legal-late-interaction.tex" (interaction late)
  IO.FS.writeFile "book/generated/legal-lost-events.tex" (eventTable lost)
  IO.FS.writeFile "book/generated/legal-provenance.txt" (reprStr provenance ++ "\n")
  for h in histories do
    IO.println (h.key ++ ": " ++ verdict h ++ " | s1 " ++ (act1 h).text ++ ", s2 " ++ (act2 h).text ++ ", s3 " ++ (act3 h).text ++
      ", s4 " ++ (act4 h).text ++ " | code " ++ (codeA h).text ++ "/" ++ (codeB h).text ++ "/" ++ (codeC h).text)
  IO.println "ok: legal deposit example generated"

end LegalDepositExample

def main : IO Unit := LegalDepositExample.main
