import LeanFM.UiModel

namespace LeanFM

inductive PropertyMode where
  | eventually
  | always
  | never
  | preparedFor
deriving DecidableEq, Repr

inductive ChartKind where
  | xy
  | pie
deriving DecidableEq, Repr

structure MessageSchema where
  name : String
  src : String
  dst : String
  bytes : List Nat
  fields : List String
deriving Repr

structure RequirementState where
  id : String
  label : String
  group : String
  markdown : String
  terminal : Bool
deriving Repr

structure RequirementTransition where
  src : String
  dst : String
  message : String
  probabilityNum : Nat
  probabilityDen : Nat
  dwellMs : Nat
deriving Repr

structure TaskRequirement where
  id : String
  title : String
  actors : List String
  initialState : String
  states : List RequirementState
  transitions : List RequirementTransition
deriving Repr

structure RequirementProperty where
  name : String
  mode : PropertyMode
  task : String
  expression : String
deriving Repr

structure RequirementChart where
  name : String
  kind : ChartKind
  source : String
  groupBy : Option String
  value : String
deriving Repr

structure RequirementMarkdown where
  id : String
  title : String
  body : String
deriving Repr

structure RequirementSpec where
  id : String
  title : String
  actors : List String
  messages : List MessageSchema
  tasks : List TaskRequirement
  properties : List RequirementProperty
  charts : List RequirementChart
  markdown : List RequirementMarkdown
deriving Repr

inductive GeneratedArtifact where
  | requirement : RequirementSpec -> GeneratedArtifact
deriving Repr

def GeneratedArtifact.id : GeneratedArtifact -> String
  | .requirement spec => spec.id

def GeneratedArtifact.title : GeneratedArtifact -> String
  | .requirement spec => spec.title

def messageNames (spec : RequirementSpec) : List String :=
  spec.messages.map (fun m => m.name)

def taskIds (spec : RequirementSpec) : List String :=
  spec.tasks.map (fun t => t.id)

def stateIds (task : TaskRequirement) : List String :=
  task.states.map (fun s => s.id)

def validateMessageSchema (actors : List String) (msg : MessageSchema) : List String :=
  (if msg.name == "" then ["message has empty name"] else []) ++
  (if actors.contains msg.src then [] else ["message " ++ msg.name ++ " has unknown src actor: " ++ msg.src]) ++
  (if actors.contains msg.dst then [] else ["message " ++ msg.name ++ " has unknown dst actor: " ++ msg.dst]) ++
  (if msg.bytes.isEmpty then ["message " ++ msg.name ++ " has no byte grammar"] else []) ++
  (if msg.fields.isEmpty then ["message " ++ msg.name ++ " has no visible fields"] else [])

def validateTaskRequirement (spec : RequirementSpec) (task : TaskRequirement) : List String :=
  let ids := stateIds task
  let duplicates := (duplicateStrings ids).map fun id => "task " ++ task.id ++ " has duplicate state: " ++ id
  let stateErrors :=
    task.states.foldr
      (fun state acc =>
        (if state.id == "" then ["task " ++ task.id ++ " has state with empty id"] else []) ++
        (if state.label == "" then ["task " ++ task.id ++ " state " ++ state.id ++ " has empty label"] else []) ++
        (if state.group == "" then ["task " ++ task.id ++ " state " ++ state.id ++ " has empty group"] else []) ++
        acc)
      []
  let transitionErrors :=
    task.transitions.foldr
      (fun tr acc =>
        (if ids.contains tr.src then [] else ["task " ++ task.id ++ " transition has unknown src: " ++ tr.src]) ++
        (if ids.contains tr.dst then [] else ["task " ++ task.id ++ " transition has unknown dst: " ++ tr.dst]) ++
        (if (messageNames spec).contains tr.message then [] else ["task " ++ task.id ++ " transition references unknown message: " ++ tr.message]) ++
        (if tr.probabilityDen == 0 then ["task " ++ task.id ++ " transition " ++ tr.message ++ " has zero probability denominator"] else []) ++
        (if tr.probabilityNum > tr.probabilityDen then ["task " ++ task.id ++ " transition " ++ tr.message ++ " probability exceeds denominator"] else []) ++
        acc)
      []
  (if task.id == "" then ["task has empty id"] else []) ++
  (if task.title == "" then ["task " ++ task.id ++ " has empty title"] else []) ++
  (if task.states.isEmpty then ["task " ++ task.id ++ " has no states"] else []) ++
  (if ids.contains task.initialState then [] else ["task " ++ task.id ++ " initial state is not listed: " ++ task.initialState]) ++
  (task.actors.filterMap fun actor =>
    if spec.actors.contains actor then none else some ("task " ++ task.id ++ " has unknown actor: " ++ actor)) ++
  duplicates ++ stateErrors ++ transitionErrors

def validateRequirementSpec (spec : RequirementSpec) : List String :=
  let duplicateActors := (duplicateStrings spec.actors).map fun id => "duplicate actor: " ++ id
  let duplicateMessages := (duplicateStrings (messageNames spec)).map fun id => "duplicate message: " ++ id
  let duplicateTasks := (duplicateStrings (taskIds spec)).map fun id => "duplicate task: " ++ id
  let messageErrors := spec.messages.foldr (fun msg acc => validateMessageSchema spec.actors msg ++ acc) []
  let taskErrors := spec.tasks.foldr (fun task acc => validateTaskRequirement spec task ++ acc) []
  let propertyErrors :=
    spec.properties.foldr
      (fun prop acc =>
        (if prop.name == "" then ["property has empty name"] else []) ++
        (if (taskIds spec).contains prop.task then [] else ["property " ++ prop.name ++ " references unknown task: " ++ prop.task]) ++
        (if prop.expression == "" then ["property " ++ prop.name ++ " has empty expression"] else []) ++
        acc)
      []
  let chartErrors :=
    spec.charts.foldr
      (fun chart acc =>
        (if chart.name == "" then ["chart has empty name"] else []) ++
        (if chart.source == "" then ["chart " ++ chart.name ++ " has empty source"] else []) ++
        (if chart.value == "" then ["chart " ++ chart.name ++ " has empty value"] else []) ++
        acc)
      []
  let markdownErrors :=
    spec.markdown.foldr
      (fun md acc =>
        (if md.id == "" then ["markdown block has empty id"] else []) ++
        (if md.title == "" then ["markdown " ++ md.id ++ " has empty title"] else []) ++
        (if md.body == "" then ["markdown " ++ md.id ++ " has empty body"] else []) ++
        acc)
      []
  (if spec.id == "" then ["requirement has empty id"] else []) ++
  (if spec.title == "" then ["requirement " ++ spec.id ++ " has empty title"] else []) ++
  (if spec.actors.isEmpty then ["requirement " ++ spec.id ++ " has no actors"] else []) ++
  (if spec.messages.isEmpty then ["requirement " ++ spec.id ++ " has no message schemas"] else []) ++
  (if spec.tasks.isEmpty then ["requirement " ++ spec.id ++ " has no task FSMs"] else []) ++
  duplicateActors ++ duplicateMessages ++ duplicateTasks ++ messageErrors ++ taskErrors ++ propertyErrors ++ chartErrors ++ markdownErrors

def transitionMessageLabel (spec : RequirementSpec) (message : String) : String :=
  match spec.messages.find? (fun msg => msg.name == message) with
  | some msg => msg.src ++ "->" ++ msg.dst ++ ": " ++ msg.name
  | none => message

def taskToAggregateNodes (task : TaskRequirement) : List AggregateNode :=
  task.states.map fun state =>
    { id := task.id ++ "." ++ state.id
    , group := task.title
    , sub := state.group
    , task := task.id
    , auth := ""
    , terminal := state.terminal
    , q := 0
    , label := state.label
    }

def taskToAggregateEdges (spec : RequirementSpec) (task : TaskRequirement) : List AggregateEdge :=
  task.transitions.map fun tr =>
    { src := task.id ++ "." ++ tr.src
    , dst := task.id ++ "." ++ tr.dst
    , label := transitionMessageLabel spec tr.message
    }

def concatLists : List (List α) -> List α
  | [] => []
  | xs :: rest => xs ++ concatLists rest

def requirementAggregateGraphData (spec : RequirementSpec) : AggregateGraphData :=
  { nodes := concatLists (spec.tasks.map taskToAggregateNodes)
  , edges := concatLists (spec.tasks.map (taskToAggregateEdges spec))
  }

def validateGeneratedArtifact : GeneratedArtifact -> List String
  | .requirement spec =>
      validateRequirementSpec spec ++
      (validateAggregateGraph (requirementAggregateGraphData spec)).map (fun msg => "derived graph: " ++ msg)

def validateGeneratedArtifacts (artifacts : List GeneratedArtifact) : List String :=
  artifacts.foldr (fun artifact acc => validateGeneratedArtifact artifact ++ acc) []

def generatedArtifactValidationReport (artifacts : List GeneratedArtifact) : String :=
  match validateGeneratedArtifacts artifacts with
  | [] => "ok: all generated artifacts are well-formed typed Lean values\n"
  | errors => "invalid generated artifacts\n" ++ joinWithNewline errors ++ "\n"

end LeanFM
