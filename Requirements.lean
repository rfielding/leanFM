namespace LeanFM

/-- A draft requirement created while iterating with an LLM or stakeholder. -/
structure RequirementDraft where
  id : String
  title : String
  description : String
  formalization : Prop

/-- A committed requirement is only accepted once Lean has checked a proof. -/
structure AcceptedRequirement where
  id : String
  title : String
  description : String
  formalization : Prop
  proof : formalization

def accept (draft : RequirementDraft) (proof : draft.formalization) : AcceptedRequirement where
  id := draft.id
  title := draft.title
  description := draft.description
  formalization := draft.formalization
  proof := proof

def req001Draft : RequirementDraft where
  id := "REQ-001"
  title := "Requirements are stored as Lean"
  description :=
    "Accepted requirements are captured in a Lean file so they can be versioned and reviewed."
  formalization := True

def req001 : AcceptedRequirement :=
  accept req001Draft trivial

def req002Draft : RequirementDraft where
  id := "REQ-002"
  title := "Committed requirements are checkable"
  description :=
    "Every accepted requirement carries a Lean proof, so the repository only commits checked requirements."
  formalization := ∀ requirement : AcceptedRequirement, requirement.formalization

def req002 : AcceptedRequirement :=
  accept req002Draft (by
    intro requirement
    exact requirement.proof)

def req003Draft : RequirementDraft where
  id := "REQ-003"
  title := "Negotiation ends with an accepted Lean artifact"
  description :=
    "A draft requirement can be turned into a committed requirement by supplying a proof of its formalization."
  formalization := req001.title = req001Draft.title

def req003 : AcceptedRequirement :=
  accept req003Draft rfl

def committedRequirements : List AcceptedRequirement :=
  [req001, req002, req003]

def committedRequirementIds : List String :=
  committedRequirements.map AcceptedRequirement.id

example : req001.formalization := req001.proof

example : req002.formalization := req002.proof

example : req003.formalization := req003.proof

example : committedRequirementIds = ["REQ-001", "REQ-002", "REQ-003"] := rfl

end LeanFM
