import LeanFM.UiModel

namespace LeanFM

inductive NameStyle where
  | raw
  | dot
deriving DecidableEq, Repr

class RequirementName (α : Type) where
  style : NameStyle := NameStyle.raw

def charsAfterLastDot : List Char -> List Char -> List Char
  | [], current => current
  | c :: rest, current =>
      if c == '.' then
        charsAfterLastDot rest []
      else
        charsAfterLastDot rest (current ++ [c])

def constructorToken [Repr α] (value : α) : String :=
  String.ofList <| charsAfterLastDot (reprStr value).toList []

def replaceChar (needle replacement : Char) (s : String) : String :=
  String.ofList <| s.toList.map fun c => if c == needle then replacement else c

def applyNameStyle : NameStyle -> String -> String
  | .raw, name => name
  | .dot, name => replaceChar '_' '.' name

def requirementName [Repr α] [RequirementName α] (value : α) : String :=
  applyNameStyle (RequirementName.style (α := α)) (constructorToken value)

inductive PropertyMode where
  | eventually
  | always
  | never
  | preparedFor
deriving DecidableEq, Repr

inductive RequiredProofMode where
  | never
  | always
  | eventually
  | possibly
deriving DecidableEq, Repr

structure Probability where
  numerator : Nat
  denominator : Nat
deriving DecidableEq, Repr

def Probability.isValid (p : Probability) : Bool :=
  p.denominator != 0 && p.numerator <= p.denominator

structure RequiredProof where
  name : String
  mode : RequiredProofMode
  task : String
  predicate : String
  probability : Option Probability
deriving Repr

inductive ChartKind where
  | xy
  | pie
deriving DecidableEq, Repr

inductive ProtoScalar where
  | string
  | bool
  | uint32
  | uint64
  | bytes
deriving DecidableEq, Repr

def ProtoScalar.protoName : ProtoScalar -> String
  | .string => "string"
  | .bool => "bool"
  | .uint32 => "uint32"
  | .uint64 => "uint64"
  | .bytes => "bytes"

inductive FramingKind where
  | protobufMessage
  | protobufOneof
  | transportEnvelope
deriving DecidableEq, Repr

def FramingKind.describe : FramingKind -> String
  | .protobufMessage => "protobuf message bytes"
  | .protobufOneof => "protobuf oneof dispatch"
  | .transportEnvelope => "transport envelope dispatch"

structure MessageFraming where
  kind : FramingKind
  dispatchField : Option String
  note : String
deriving Repr

structure ProtoFieldSchema where
  number : Nat
  name : String
  scalar : ProtoScalar
deriving Repr

structure MessageSchema where
  name : String
  src : String
  dst : String
  framing : MessageFraming
  fields : List ProtoFieldSchema
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

structure GrammarAtom where
  task : String
  src : String
  dst : String
  message : String
deriving Repr

inductive GrammarExpr where
  | empty
  | event : GrammarAtom -> GrammarExpr
  | seq : GrammarExpr -> GrammarExpr -> GrammarExpr
  | choice : List GrammarExpr -> GrammarExpr
  | parallel : GrammarExpr -> GrammarExpr -> GrammarExpr
  | guard : String -> GrammarExpr -> GrammarExpr
  | ref : String -> GrammarExpr
  | repeat : GrammarExpr -> GrammarExpr
deriving Repr

namespace GrammarExpr

def eps : GrammarExpr :=
  GrammarExpr.empty

def seqList : List GrammarExpr -> GrammarExpr
  | [] => GrammarExpr.empty
  | [x] => x
  | x :: xs => GrammarExpr.seq x (seqList xs)

def alt : List GrammarExpr -> GrammarExpr :=
  GrammarExpr.choice

def par : GrammarExpr -> GrammarExpr -> GrammarExpr :=
  GrammarExpr.parallel

def when (predicate : String) (body : GrammarExpr) : GrammarExpr :=
  GrammarExpr.guard predicate body

def nonterminal (task : String) : GrammarExpr :=
  GrammarExpr.ref task

def optional (body : GrammarExpr) : GrammarExpr :=
  GrammarExpr.choice [GrammarExpr.empty, body]

def star (body : GrammarExpr) : GrammarExpr :=
  GrammarExpr.repeat body

def plus (body : GrammarExpr) : GrammarExpr :=
  GrammarExpr.seq body (GrammarExpr.repeat body)

infixr:55 " >>> " => GrammarExpr.seq
infixr:50 " <||> " => fun left right => GrammarExpr.choice [left, right]

end GrammarExpr

structure TaskGrammar where
  task : String
  entry : String
  terminals : List String
  body : GrammarExpr
deriving Repr

structure RequirementProperty where
  name : String
  mode : PropertyMode
  task : String
  expression : String
  probability : Option Probability
deriving Repr

structure RequirementChart where
  name : String
  kind : ChartKind
  source : String
  groupBy : Option String
  value : String
deriving Repr

inductive PerformanceMetric where
  | clientExperiencedRate
  | serverAggregateRate
deriving DecidableEq, Repr

/-- A minimum non-functional work rate, expressed as work units per millisecond. -/
structure PerformanceRequirement where
  name : String
  task : String
  metric : PerformanceMetric
  workField : String
  minimumWork : Nat
  perMilliseconds : Nat
deriving Repr

structure RequirementProcess where
  actor : String
  task : String
  states : List String
  sends : List String
  receives : List String
deriving Repr

structure RequirementMarkdown where
  id : String
  title : String
  body : String
deriving Repr

/-- Finite resource bounds that an implementation must enforce for one actor. -/
structure ActorResourceContract where
  actor : String
  inboundCapacity : Nat
  outboundCapacity : Nat
  maxInFlight : Nat
  memoryBudgetBytes : Nat
deriving Repr

/-- Specified reliability assumptions for every instance of an actor spec. -/
structure ActorReliabilityContract where
  actor : String
  outageProbability : Probability
  meanTimeToRepairMs : Nat
deriving Repr

/-- A reusable actor specification may be instantiated many times. -/
structure ActorPopulation where
  actorSpec : String
  instancePrefix : String
  count : Nat
deriving DecidableEq, Repr

def ActorPopulation.instanceIds (population : ActorPopulation) : List String :=
  (List.range population.count).map fun index =>
    population.instancePrefix ++ toString (index + 1)

structure RequirementSpec where
  id : String
  title : String
  actors : List String
  actorPopulations : List ActorPopulation
  actorResources : List ActorResourceContract
  actorReliability : List ActorReliabilityContract
  messages : List MessageSchema
  tasks : List TaskRequirement
  grammars : List TaskGrammar
  processes : List RequirementProcess
  properties : List RequirementProperty
  requiredProofs : List RequiredProof
  performance : List PerformanceRequirement
  charts : List RequirementChart
  markdown : List RequirementMarkdown
deriving Repr

def RequirementSpec.actorInstances (spec : RequirementSpec) : List String :=
  spec.actorPopulations.flatMap ActorPopulation.instanceIds

inductive TargetLanguage where
  | go
  | rust
  | lean
deriving DecidableEq, Repr

structure ActorCodegen where
  actor : String
  typeName : String
  sourceFile : String
deriving Repr

/-- How protobuf bytes are carried is an implementation choice, not a wire-schema fact. -/
inductive TransportSpec where
  | httpRequest (method : String) (path : String)
  | httpResponse (requestMessage : String)
  | inProcessChannel (channelName : String)
  | tcp (endpoint : String)
  | custom (adapter : String) (configuration : String)
deriving Repr

structure MessageCodegen where
  message : String
  wireType : String
  transport : TransportSpec
deriving Repr

inductive SendFullSemantics where
  | blockWithoutMutation
deriving DecidableEq, Repr

inductive ReceiveEmptySemantics where
  | blockWithoutMutation
deriving DecidableEq, Repr

inductive TryReceiveEmptySemantics where
  | returnNoneKeepRunnable
deriving DecidableEq, Repr

structure ChannelCodegen where
  sendFunction : String
  receiveFunction : String
  tryReceiveFunction : String
  sendFull : SendFullSemantics
  receiveEmpty : ReceiveEmptySemantics
  tryReceiveEmpty : TryReceiveEmptySemantics
deriving Repr

/-- Implementation/code-generation decisions kept separate from requirements. -/
structure ImplementationSpec where
  requirementId : String
  target : TargetLanguage
  moduleName : String
  outputDirectory : String
  actors : List ActorCodegen
  messages : List MessageCodegen
  channels : ChannelCodegen
deriving Repr

structure TypedMessageSchema (Actor Message : Type) where
  name : Message
  src : Actor
  dst : Actor
  framing : MessageFraming
  fields : List ProtoFieldSchema
deriving Repr

structure TypedRequirementState (State : Type) where
  id : State
  label : String
  group : String
  markdown : String
  terminal : Bool
deriving Repr

structure TypedRequirementTransition (State Message : Type) where
  src : State
  dst : State
  message : Message
  probabilityNum : Nat
  probabilityDen : Nat
  dwellMs : Nat
deriving Repr

structure TypedTaskRequirement (Actor State Message : Type) where
  id : String
  title : String
  actors : List Actor
  initialState : State
  states : List (TypedRequirementState State)
  transitions : List (TypedRequirementTransition State Message)
deriving Repr

structure TypedRequirementProcess (Actor State Message : Type) where
  actor : Actor
  task : String
  states : List State
  sends : List Message
  receives : List Message
deriving Repr

def typedMessageSchemaToSchema [Repr Actor] [RequirementName Actor] [Repr Message] [RequirementName Message]
    (msg : TypedMessageSchema Actor Message) : MessageSchema :=
  { name := requirementName msg.name
  , src := requirementName msg.src
  , dst := requirementName msg.dst
  , framing := msg.framing
  , fields := msg.fields
  }

def typedRequirementStateToState [Repr State] [RequirementName State]
    (state : TypedRequirementState State) : RequirementState :=
  { id := requirementName state.id
  , label := state.label
  , group := state.group
  , markdown := state.markdown
  , terminal := state.terminal
  }

def typedRequirementTransitionToTransition [Repr State] [RequirementName State] [Repr Message] [RequirementName Message]
    (tr : TypedRequirementTransition State Message) : RequirementTransition :=
  { src := requirementName tr.src
  , dst := requirementName tr.dst
  , message := requirementName tr.message
  , probabilityNum := tr.probabilityNum
  , probabilityDen := tr.probabilityDen
  , dwellMs := tr.dwellMs
  }

def typedTaskRequirementToTask [Repr Actor] [RequirementName Actor] [Repr State] [RequirementName State] [Repr Message] [RequirementName Message]
    (task : TypedTaskRequirement Actor State Message) : TaskRequirement :=
  { id := task.id
  , title := task.title
  , actors := task.actors.map requirementName
  , initialState := requirementName task.initialState
  , states := task.states.map typedRequirementStateToState
  , transitions := task.transitions.map typedRequirementTransitionToTransition
  }

def typedRequirementProcessToProcess [Repr Actor] [RequirementName Actor] [Repr State] [RequirementName State] [Repr Message] [RequirementName Message]
    (process : TypedRequirementProcess Actor State Message) : RequirementProcess :=
  { actor := requirementName process.actor
  , task := process.task
  , states := process.states.map requirementName
  , sends := process.sends.map requirementName
  , receives := process.receives.map requirementName
  }

inductive GeneratedRequirement where
  | requirement : RequirementSpec -> GeneratedRequirement
deriving Repr

def GeneratedRequirement.id : GeneratedRequirement -> String
  | .requirement spec => spec.id

def GeneratedRequirement.title : GeneratedRequirement -> String
  | .requirement spec => spec.title

def messageNames (spec : RequirementSpec) : List String :=
  spec.messages.map (fun m => m.name)

def findMessage? (spec : RequirementSpec) (name : String) : Option MessageSchema :=
  spec.messages.find? (fun msg => msg.name == name)

def taskIds (spec : RequirementSpec) : List String :=
  spec.tasks.map (fun t => t.id)

def stateIds (task : TaskRequirement) : List String :=
  task.states.map (fun s => s.id)

def taskProperties (spec : RequirementSpec) (task : String) : List RequirementProperty :=
  spec.properties.filter (fun prop => prop.task == task)

def taskProcesses (spec : RequirementSpec) (task : String) : List RequirementProcess :=
  spec.processes.filter (fun process => process.task == task)

def actorResourceActors (spec : RequirementSpec) : List String :=
  spec.actorResources.map (fun resource => resource.actor)

def validateActorResourceContract (actors : List String)
    (resource : ActorResourceContract) : List String :=
  (if actors.contains resource.actor then [] else
    ["resource contract references unknown actor: " ++ resource.actor]) ++
  (if resource.inboundCapacity > 0 then [] else
    ["actor " ++ resource.actor ++ " has zero inbound queue capacity"]) ++
  (if resource.outboundCapacity > 0 then [] else
    ["actor " ++ resource.actor ++ " has zero outbound queue capacity"]) ++
  (if resource.maxInFlight > 0 then [] else
    ["actor " ++ resource.actor ++ " has zero max in-flight work capacity"]) ++
  (if resource.memoryBudgetBytes > 0 then [] else
    ["actor " ++ resource.actor ++ " has zero memory budget"])

def validateActorResources (actors : List String)
    (resources : List ActorResourceContract) : List String :=
  let resourceActors := resources.map (fun resource => resource.actor)
  let duplicates :=
    (duplicateStrings resourceActors).map fun id =>
      "duplicate resource contract for actor: " ++ id
  let missing :=
    actors.filterMap fun actor =>
      if resourceActors.contains actor then none else
        some ("actor has no finite resource contract: " ++ actor)
  let contractErrors :=
    resources.foldr
      (fun resource acc => validateActorResourceContract actors resource ++ acc) []
  duplicates ++ missing ++ contractErrors

def taskTransitionMessages (task : TaskRequirement) : List String :=
  task.transitions.map (fun tr => tr.message)

def grammarIds (spec : RequirementSpec) : List String :=
  spec.grammars.map (fun grammar => grammar.task)

partial def grammarAtoms : GrammarExpr -> List GrammarAtom
  | GrammarExpr.empty => []
  | GrammarExpr.event atom => [atom]
  | GrammarExpr.seq left right => grammarAtoms left ++ grammarAtoms right
  | GrammarExpr.choice branches => branches.foldr (fun branch acc => grammarAtoms branch ++ acc) []
  | GrammarExpr.parallel left right => grammarAtoms left ++ grammarAtoms right
  | GrammarExpr.guard _ body => grammarAtoms body
  | GrammarExpr.ref _ => []
  | GrammarExpr.repeat body => grammarAtoms body

partial def grammarRefs : GrammarExpr -> List String
  | GrammarExpr.empty => []
  | GrammarExpr.event _ => []
  | GrammarExpr.seq left right => grammarRefs left ++ grammarRefs right
  | GrammarExpr.choice branches => branches.foldr (fun branch acc => grammarRefs branch ++ acc) []
  | GrammarExpr.parallel left right => grammarRefs left ++ grammarRefs right
  | GrammarExpr.guard _ body => grammarRefs body
  | GrammarExpr.ref task => [task]
  | GrammarExpr.repeat body => grammarRefs body

def listIntersects [DecidableEq α] (xs ys : List α) : Bool :=
  xs.any (fun x => ys.contains x)

def messageSentBy (spec : RequirementSpec) (actor message : String) : Bool :=
  match findMessage? spec message with
  | some msg => msg.src == actor
  | none => false

def messageReceivedBy (spec : RequirementSpec) (actor message : String) : Bool :=
  match findMessage? spec message with
  | some msg => msg.dst == actor
  | none => false

def transitionUsesInterActorMessage (spec : RequirementSpec) (tr : RequirementTransition) : Bool :=
  match findMessage? spec tr.message with
  | some msg => msg.src != msg.dst
  | none => false

def natStrings (xs : List Nat) : List String :=
  xs.map (fun n => toString n)

def validateProtoFieldSchema (messageName : String) (field : ProtoFieldSchema) : List String :=
  (if field.number == 0 then ["message " ++ messageName ++ " has protobuf field " ++ field.name ++ " with tag 0"] else []) ++
  (if field.name == "" then ["message " ++ messageName ++ " has protobuf field with empty name"] else [])

def validateMessageFraming (messageName : String) (framing : MessageFraming) : List String :=
  let dispatchErrors :=
    match framing.kind, framing.dispatchField with
    | FramingKind.protobufMessage, _ => []
    | _, some _ => []
    | _, none => ["message " ++ messageName ++ " framing requires a dispatchField"]
  dispatchErrors ++
  (if framing.note == "" then ["message " ++ messageName ++ " framing has empty note"] else [])

def validateMessageSchema (actors : List String) (msg : MessageSchema) : List String :=
  let duplicateFieldNumbers := (duplicateStrings (natStrings (msg.fields.map (fun f => f.number)))).map fun tag =>
    "message " ++ msg.name ++ " has duplicate protobuf field tag: " ++ tag
  let duplicateFieldNames := (duplicateStrings (msg.fields.map (fun f => f.name))).map fun name =>
    "message " ++ msg.name ++ " has duplicate protobuf field name: " ++ name
  let fieldErrors := msg.fields.foldr (fun field acc => validateProtoFieldSchema msg.name field ++ acc) []
  (if msg.name == "" then ["message has empty name"] else []) ++
  (if actors.contains msg.src then [] else ["message " ++ msg.name ++ " has unknown src actor: " ++ msg.src]) ++
  (if actors.contains msg.dst then [] else ["message " ++ msg.name ++ " has unknown dst actor: " ++ msg.dst]) ++
  validateMessageFraming msg.name msg.framing ++
  (if msg.fields.isEmpty then ["message " ++ msg.name ++ " has no visible fields"] else []) ++
  duplicateFieldNumbers ++ duplicateFieldNames ++ fieldErrors

def validateTaskRequirement (spec : RequirementSpec) (task : TaskRequirement) : List String :=
  let ids := stateIds task
  let duplicates := (duplicateStrings ids).map fun id => "task " ++ task.id ++ " has duplicate state: " ++ id
  let hasInterActorMessage := task.transitions.any (transitionUsesInterActorMessage spec)
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
  (if task.actors.length < 2 then ["task " ++ task.id ++ " is vacuous: it must involve at least two actors"] else []) ++
  (if task.states.isEmpty then ["task " ++ task.id ++ " has no states"] else []) ++
  (if task.transitions.isEmpty then ["task " ++ task.id ++ " is vacuous: it has no message transitions"] else []) ++
  (if task.states.any (fun s => s.terminal) then [] else ["task " ++ task.id ++ " has no terminal state"] ) ++
  (if hasInterActorMessage then [] else ["task " ++ task.id ++ " is vacuous: it has no inter-actor message transition"] ) ++
  (if (taskProperties spec task.id).isEmpty then ["task " ++ task.id ++ " has no temporal/property annotations"] else []) ++
  (if ids.contains task.initialState then [] else ["task " ++ task.id ++ " initial state is not listed: " ++ task.initialState]) ++
  (task.actors.filterMap fun actor =>
    if spec.actors.contains actor then none else some ("task " ++ task.id ++ " has unknown actor: " ++ actor)) ++
  duplicates ++ stateErrors ++ transitionErrors

def validateRequirementProcess (spec : RequirementSpec) (process : RequirementProcess) : List String :=
  let maybeTask := spec.tasks.find? (fun task => task.id == process.task)
  let taskStateIds :=
    match maybeTask with
    | some task => stateIds task
    | none => []
  let taskMessageNames :=
    match maybeTask with
    | some task => taskTransitionMessages task
    | none => []
  (if spec.actors.contains process.actor then [] else ["process has unknown actor: " ++ process.actor]) ++
  (if (taskIds spec).contains process.task then [] else ["process " ++ process.actor ++ " references unknown task: " ++ process.task]) ++
  (if process.states.isEmpty then ["process " ++ process.actor ++ "/" ++ process.task ++ " is vacuous: it has no local states"] else []) ++
  (process.states.filterMap fun state =>
    if taskStateIds.contains state then none else some ("process " ++ process.actor ++ "/" ++ process.task ++ " references unknown task state: " ++ state)) ++
  (process.sends.filterMap fun msg =>
    if !taskMessageNames.contains msg then
      some ("process " ++ process.actor ++ "/" ++ process.task ++ " sends message outside task transitions: " ++ msg)
    else if messageSentBy spec process.actor msg then
      none
    else
      some ("process " ++ process.actor ++ "/" ++ process.task ++ " sends message with different src actor: " ++ msg)) ++
  (process.receives.filterMap fun msg =>
    if !taskMessageNames.contains msg then
      some ("process " ++ process.actor ++ "/" ++ process.task ++ " receives message outside task transitions: " ++ msg)
    else if messageReceivedBy spec process.actor msg then
      none
    else
      some ("process " ++ process.actor ++ "/" ++ process.task ++ " receives message with different dst actor: " ++ msg))

def validateTaskProcesses (spec : RequirementSpec) (task : TaskRequirement) : List String :=
  let processes := taskProcesses spec task.id
  let processActors := processes.map (fun process => process.actor)
  let processTraffic := processes.any (fun process => !process.sends.isEmpty || !process.receives.isEmpty)
  let missingProcesses := task.actors.filterMap fun actor =>
    if processActors.contains actor then none else some ("task " ++ task.id ++ " lacks communicating sequential process for actor: " ++ actor)
  let idleProcesses := processes.filterMap fun process =>
    if process.sends.isEmpty && process.receives.isEmpty then
      some ("process " ++ process.actor ++ "/" ++ process.task ++ " is vacuous: it neither sends nor receives")
    else
      none
  (if processes.isEmpty then ["task " ++ task.id ++ " has no communicating sequential processes"] else []) ++
  (if processTraffic then [] else ["task " ++ task.id ++ " has no process send/receive traffic"] ) ++
  missingProcesses ++ idleProcesses

def validateTaskTransitionProcessCoverage (spec : RequirementSpec) (task : TaskRequirement) : List String :=
  let processes := taskProcesses spec task.id
  task.transitions.foldr
    (fun tr acc =>
      let senderCovered :=
        processes.any (fun process => process.sends.contains tr.message)
      let receiverCovered :=
        processes.any (fun process => process.receives.contains tr.message)
      (if senderCovered then [] else ["task " ++ task.id ++ " transition " ++ tr.message ++ " has no sending process"]) ++
      (if receiverCovered then [] else ["task " ++ task.id ++ " transition " ++ tr.message ++ " has no receiving process"]) ++
      acc)
    []

def validateGrammarAtom (spec : RequirementSpec) (grammar : TaskGrammar) (atom : GrammarAtom) : List String :=
  match findMessage? spec atom.message with
  | none => ["grammar " ++ grammar.task ++ " references unknown message: " ++ atom.message]
  | some msg =>
      (if atom.task == grammar.task then [] else ["grammar " ++ grammar.task ++ " contains atom for different task: " ++ atom.task]) ++
      (if atom.src == msg.src then [] else ["grammar " ++ grammar.task ++ " atom " ++ atom.message ++ " has src " ++ atom.src ++ " but message src is " ++ msg.src]) ++
      (if atom.dst == msg.dst then [] else ["grammar " ++ grammar.task ++ " atom " ++ atom.message ++ " has dst " ++ atom.dst ++ " but message dst is " ++ msg.dst])

def validateTaskGrammar (spec : RequirementSpec) (grammar : TaskGrammar) : List String :=
  let maybeTask := spec.tasks.find? (fun task => task.id == grammar.task)
  let taskStateIds :=
    match maybeTask with
    | some task => stateIds task
    | none => []
  let atoms := grammarAtoms grammar.body
  let refs := grammarRefs grammar.body
  (if (taskIds spec).contains grammar.task then [] else ["grammar references unknown task: " ++ grammar.task]) ++
  (if taskStateIds.contains grammar.entry then [] else ["grammar " ++ grammar.task ++ " entry is not a task state: " ++ grammar.entry]) ++
  (grammar.terminals.filterMap fun terminal =>
    if taskStateIds.contains terminal then none else some ("grammar " ++ grammar.task ++ " terminal is not a task state: " ++ terminal)) ++
  (if atoms.isEmpty then ["grammar " ++ grammar.task ++ " has no event atoms"] else []) ++
  refs.filterMap (fun task =>
    if (taskIds spec).contains task then none else some ("grammar " ++ grammar.task ++ " references unknown grammar task: " ++ task)) ++
  atoms.foldr (fun atom acc => validateGrammarAtom spec grammar atom ++ acc) []

def validateRequiredProof (spec : RequirementSpec) (proof : RequiredProof) : List String :=
  (if proof.name == "" then ["required proof has empty name"] else []) ++
  (if (taskIds spec).contains proof.task then [] else ["required proof " ++ proof.name ++ " references unknown task: " ++ proof.task]) ++
  (if proof.predicate == "" then ["required proof " ++ proof.name ++ " has empty predicate"] else []) ++
  (match proof.probability with
  | none => []
  | some p =>
      if p.isValid then [] else ["required proof " ++ proof.name ++ " has invalid probability"])

def validateRequirementSpec (spec : RequirementSpec) : List String :=
  let duplicateActors := (duplicateStrings spec.actors).map fun id => "duplicate actor: " ++ id
  let populationSpecs := spec.actorPopulations.map (fun population => population.actorSpec)
  let populationInstances := spec.actorInstances
  let populationErrors :=
    (duplicateStrings populationSpecs).map (fun actor => "duplicate actor population: " ++ actor) ++
    (duplicateStrings populationInstances).map (fun instanceId => "duplicate actor instance id: " ++ instanceId) ++
    spec.actors.filterMap (fun actor =>
      if populationSpecs.contains actor then none else some ("actor has no population: " ++ actor)) ++
    populationSpecs.filterMap (fun actor =>
      if spec.actors.contains actor then none else some ("population references unknown actor spec: " ++ actor)) ++
    spec.actorPopulations.foldr (fun population errors =>
      (if population.count == 0 then ["actor population has zero instances: " ++ population.actorSpec] else []) ++
      (if population.instancePrefix == "" then ["actor population has empty instance prefix: " ++ population.actorSpec] else []) ++
      errors) []
  let resourceErrors := validateActorResources spec.actors spec.actorResources
  let reliabilityActors := spec.actorReliability.map (fun contract => contract.actor)
  let reliabilityErrors :=
    (duplicateStrings reliabilityActors).map (fun actor => "duplicate actor reliability contract: " ++ actor) ++
    spec.actorReliability.foldr (fun contract errors =>
      (if spec.actors.contains contract.actor then [] else
        ["reliability contract references unknown actor: " ++ contract.actor]) ++
      (if contract.outageProbability.isValid then [] else
        ["actor has invalid outage probability: " ++ contract.actor]) ++
      (if contract.outageProbability.numerator > 0 && contract.meanTimeToRepairMs == 0 then
        ["actor with nonzero outage probability has zero MTTR: " ++ contract.actor] else []) ++
      errors) []
  let duplicateMessages := (duplicateStrings (messageNames spec)).map fun id => "duplicate message: " ++ id
  let duplicateTasks := (duplicateStrings (taskIds spec)).map fun id => "duplicate task: " ++ id
  let duplicateGrammars := (duplicateStrings (grammarIds spec)).map fun id => "duplicate grammar for task: " ++ id
  let messageErrors := spec.messages.foldr (fun msg acc => validateMessageSchema spec.actors msg ++ acc) []
  let taskErrors := spec.tasks.foldr (fun task acc => validateTaskRequirement spec task ++ validateTaskProcesses spec task ++ validateTaskTransitionProcessCoverage spec task ++ acc) []
  let grammarErrors := spec.grammars.foldr (fun grammar acc => validateTaskGrammar spec grammar ++ acc) []
  let processErrors := spec.processes.foldr (fun process acc => validateRequirementProcess spec process ++ acc) []
  let propertyErrors :=
    spec.properties.foldr
      (fun prop acc =>
        (if prop.name == "" then ["property has empty name"] else []) ++
        (if (taskIds spec).contains prop.task then [] else ["property " ++ prop.name ++ " references unknown task: " ++ prop.task]) ++
        (if prop.expression == "" then ["property " ++ prop.name ++ " has empty expression"] else []) ++
        (match prop.probability with
        | none => []
        | some p =>
            if p.isValid then [] else ["property " ++ prop.name ++ " has invalid probability"]) ++
        acc)
      []
  let proofErrors := spec.requiredProofs.foldr (fun proof acc => validateRequiredProof spec proof ++ acc) []
  let performanceErrors := spec.performance.foldr (fun requirement acc =>
    (if requirement.name == "" then ["performance requirement has empty name"] else []) ++
    (if (taskIds spec).contains requirement.task then [] else
      ["performance requirement " ++ requirement.name ++ " references unknown task: " ++ requirement.task]) ++
    (if requirement.workField == "" then ["performance requirement has empty work field: " ++ requirement.name] else []) ++
    (if requirement.minimumWork == 0 then ["performance requirement has zero minimum work: " ++ requirement.name] else []) ++
    (if requirement.perMilliseconds == 0 then ["performance requirement has zero time denominator: " ++ requirement.name] else []) ++
    acc) []
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
  (if spec.grammars.isEmpty then ["requirement " ++ spec.id ++ " has no multiparty grammars"] else []) ++
  (if spec.processes.isEmpty then ["requirement " ++ spec.id ++ " has no communicating sequential processes"] else []) ++
  (if spec.properties.isEmpty then ["requirement " ++ spec.id ++ " has no temporal/property annotations"] else []) ++
  (if spec.requiredProofs.isEmpty then ["requirement " ++ spec.id ++ " has no required proof obligations"] else []) ++
  duplicateActors ++ populationErrors ++ resourceErrors ++ reliabilityErrors ++
    duplicateMessages ++ duplicateTasks ++ duplicateGrammars ++ messageErrors ++ taskErrors ++
    grammarErrors ++ processErrors ++ propertyErrors ++ proofErrors ++ performanceErrors ++ chartErrors ++ markdownErrors

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

def propertyModeName : PropertyMode -> String
  | .eventually => "eventually"
  | .always => "always"
  | .never => "never"
  | .preparedFor => "preparedFor"

def taskPropertyNodes (spec : RequirementSpec) (task : TaskRequirement) : List AggregateNode :=
  (taskProperties spec task.id).map fun prop =>
    { id := task.id ++ ".property." ++ prop.name
    , group := task.title
    , sub := "temporal logic"
    , task := task.id
    , auth := ""
    , terminal := false
    , q := 0
    , label := propertyModeName prop.mode ++ ": " ++ prop.expression
    }

def taskPropertyEdges (spec : RequirementSpec) (task : TaskRequirement) : List AggregateEdge :=
  (taskProperties spec task.id).map fun prop =>
    { src := task.id ++ "." ++ task.initialState
    , dst := task.id ++ ".property." ++ prop.name
    , label := "annotates CTL"
    }

def concatLists : List (List α) -> List α
  | [] => []
  | xs :: rest => xs ++ concatLists rest

def requirementAggregateGraphData (spec : RequirementSpec) : AggregateGraphData :=
  { nodes := concatLists (spec.tasks.map (fun task => taskToAggregateNodes task ++ taskPropertyNodes spec task))
  , edges := concatLists (spec.tasks.map (fun task => taskToAggregateEdges spec task ++ taskPropertyEdges spec task))
  }

def protoMessageName (name : String) : String :=
  replaceChar '.' '_' name

def byteHex (n : Nat) : String :=
  if n < 16 then
    "0x0" ++ String.ofList (Nat.toDigits 16 n)
  else
    "0x" ++ String.ofList (Nat.toDigits 16 n)

def byteListComment (bytes : List Nat) : String :=
  joinWithComma (bytes.map byteHex)

def protoFieldLine (field : ProtoFieldSchema) : String :=
  "  " ++ field.scalar.protoName ++ " " ++ field.name ++ " = " ++ toString field.number ++ ";"

def protoMessageBlock (msg : MessageSchema) : String :=
  joinWithNewline
    ( [ "// traffic: " ++ msg.src ++ " -> " ++ msg.dst
      , "// framing: " ++ msg.framing.kind.describe
      , "// dispatch field: " ++ match msg.framing.dispatchField with | some field => field | none => "none"
      , "// framing note: " ++ msg.framing.note
      , "message " ++ protoMessageName msg.name ++ " {"
      ] ++
      msg.fields.map protoFieldLine ++
      [ "}" ] )

def requirementProtoFile (spec : RequirementSpec) : String :=
  joinWithNewline
    ( [ "syntax = \"proto3\";"
      , ""
      , "package leanfm.generated;"
      , ""
      , "// Generated from LeanFM requirement: " ++ spec.id
      , "// The comments preserve the src/dst wrapper and framing for each message atom."
      , ""
      ] ++
      spec.messages.map protoMessageBlock) ++ "\n"

def charsStartWith : List Char -> List Char -> Bool
  | _, [] => true
  | [], _ :: _ => false
  | x :: xs, y :: ys => x == y && charsStartWith xs ys

def charsContain : List Char -> List Char -> Bool
  | [], needle => needle == []
  | hay, needle =>
      charsStartWith hay needle ||
      match hay with
      | [] => false
      | _ :: rest => charsContain rest needle

def stringContains (haystack needle : String) : Bool :=
  charsContain haystack.toList needle.toList

def protoMessageDeclaration (msg : MessageSchema) : String :=
  "message " ++ protoMessageName msg.name ++ " {"

def validateRequirementProtoFile (spec : RequirementSpec) (protoText : String) : List String :=
  spec.messages.filterMap fun msg =>
    let decl := protoMessageDeclaration msg
    if stringContains protoText decl then
      none
    else
      some ("proto file is missing declaration for message atom: " ++ decl)

def validateGeneratedRequirement : GeneratedRequirement -> List String
  | .requirement spec =>
      validateRequirementSpec spec ++
      (validateAggregateGraph (requirementAggregateGraphData spec)).map (fun msg => "derived graph: " ++ msg)

def validateGeneratedRequirements (requirements : List GeneratedRequirement) : List String :=
  requirements.foldr (fun requirement acc => validateGeneratedRequirement requirement ++ acc) []

def validateImplementationSpec (requirement : RequirementSpec)
    (implementation : ImplementationSpec) : List String :=
  let implementationActors := implementation.actors.map (fun actor => actor.actor)
  let implementationMessages := implementation.messages.map (fun message => message.message)
  let missingActors := requirement.actors.filterMap fun actor =>
    if implementationActors.contains actor then none else some ("implementation has no actor binding: " ++ actor)
  let unknownActors := implementationActors.filterMap fun actor =>
    if requirement.actors.contains actor then none else some ("implementation binds unknown actor: " ++ actor)
  let missingMessages := messageNames requirement |>.filterMap fun message =>
    if implementationMessages.contains message then none else some ("implementation has no message binding: " ++ message)
  let unknownMessages := implementationMessages.filterMap fun message =>
    if (messageNames requirement).contains message then none else some ("implementation binds unknown message: " ++ message)
  (if implementation.requirementId == requirement.id then [] else
    ["implementation requirementId does not match requirement: " ++ implementation.requirementId]) ++
  (if implementation.moduleName == "" then ["implementation moduleName is empty"] else []) ++
  (if implementation.outputDirectory == "" then ["implementation outputDirectory is empty"] else []) ++
  (duplicateStrings implementationActors).map (fun actor => "duplicate implementation actor binding: " ++ actor) ++
  (duplicateStrings implementationMessages).map (fun message => "duplicate implementation message binding: " ++ message) ++
  missingActors ++ unknownActors ++ missingMessages ++ unknownMessages ++
  implementation.actors.foldr (fun actor errors =>
    (if actor.typeName == "" then ["actor binding has empty typeName: " ++ actor.actor] else []) ++
    (if actor.sourceFile == "" then ["actor binding has empty sourceFile: " ++ actor.actor] else []) ++ errors) [] ++
  implementation.messages.foldr (fun message errors =>
    (if message.wireType == "" then ["message binding has empty wireType: " ++ message.message] else []) ++
    (match message.transport with
      | .httpRequest method path =>
          (if method == "" then ["HTTP request has empty method: " ++ message.message] else []) ++
          (if path == "" then ["HTTP request has empty path: " ++ message.message] else [])
      | .httpResponse requestMessage =>
          if (messageNames requirement).contains requestMessage then []
          else ["HTTP response names unknown request message: " ++ message.message ++ " -> " ++ requestMessage]
      | .inProcessChannel channelName =>
          if channelName == "" then ["in-process transport has empty channel name: " ++ message.message] else []
      | .tcp endpoint =>
          if endpoint == "" then ["TCP transport has empty endpoint: " ++ message.message] else []
      | .custom adapter _ =>
          if adapter == "" then ["custom transport has empty adapter: " ++ message.message] else []) ++ errors) [] ++
  (if implementation.channels.sendFunction == "" then ["channel sendFunction is empty"] else []) ++
  (if implementation.channels.receiveFunction == "" then ["channel receiveFunction is empty"] else []) ++
  (if implementation.channels.tryReceiveFunction == "" then ["channel tryReceiveFunction is empty"] else [])

def implementationValidationReport (requirement : RequirementSpec)
    (implementation : ImplementationSpec) : String :=
  match validateImplementationSpec requirement implementation with
  | [] => "ok: generated implementation plan covers the requirement\n"
  | errors => "invalid generated implementation plan\n" ++ joinWithNewline errors ++ "\n"

def generatedRequirementValidationReport (requirements : List GeneratedRequirement) : String :=
  match validateGeneratedRequirements requirements with
  | [] => "ok: all generated requirements are well-formed typed Lean values\n"
  | errors => "invalid generated requirements\n" ++ joinWithNewline errors ++ "\n"

def generatedRequirementSystemPrompt : String :=
  joinWithNewline
    [ "You generate LeanFM visible-behavior requirements as Lean 4 code."
    , "You only write files under LeanFM/LLMGenerated/."
    , "The committed static DSL/runtime lives outside LeanFM/LLMGenerated/ and must be treated as read-only."
    , "Output LeanFM/LLMGenerated/Requirements.lean, LeanFM/LLMGenerated/Requirements.proto, and LeanFM/LLMGenerated/Implementation.lean."
    , "Requirements.lean contains only observable requirements. Protobuf defines values that resolve to bytes; it does not select how those bytes are transported."
    , "Define actor specifications separately from ActorPopulation values. Events use concrete instance IDs; every instance inherits the resource contract and behavior of its actorSpec."
    , "ActorReliabilityContract may specify an outage probability and meanTimeToRepairMs. Keep specified reliability assumptions distinct from outage percentages and MTTR reduced from Unavailable/Recovered events."
    , "Put target language, filenames, runtime APIs, framework choices, per-message transport choices (such as HTTP method/path), and software code-generation mappings only in Implementation.lean."
    , "Requirements.lean imports LeanFM.Artifacts and defines namespace LeanFM.LLMGenerated.Requirements."
    , "Define requirement-local inductive types for actors, message atoms, and each task's states."
    , "Each generated enum must derive DecidableEq and Repr."
    , "Provide LeanFM.RequirementName instances by naming convention, not per-constructor string matches."
    , "Use NameStyle.raw for actor and state constructors whose spellings are already the rendered names."
    , "Use NameStyle.dot for message constructors like Docs_GetRequest, which render as Docs.GetRequest."
    , "Define message atoms as List (TypedMessageSchema Actor Message)."
    , "Every message atom must have src, dst, MessageFraming, and numbered protobuf fields that correspond to a message in LLMGenerated/Requirements.proto."
    , "Requirements.proto must also define Scenario and ScenarioEvent envelopes that preserve id, repeated prior links, session, task, actors, timeAt, and the selected message atom, so a generated scenario round-trips through bytes."
    , "A terminal event of any message kind may include a backpointer to its start event in prior; use that identity and timeAt difference for duration instead of embedding startedAt/completedAt fields or guessing by adjacency."
    , "MessageFraming must say how bytes are emitted and consumed: protobufMessage, protobufOneof, or transportEnvelope."
    , "For protobufOneof or transportEnvelope framing, dispatchField must name the observable field that selects the concrete message atom."
    , "Use protobuf fields for the payload body; use task FSM transitions for valid traffic order."
    , "Define TaskGrammar values with GrammarExpr.event atoms labeled by task, src actor, dst actor, and message atom."
    , "Use GrammarExpr.seqList or the >>> notation for causality, GrammarExpr.alt or <||> for alternatives, GrammarExpr.parallel for commuting independent work, GrammarExpr.guard for context-sensitive visible facts, GrammarExpr.ref for task references, and GrammarExpr.repeat for regex-style repetition."
    , "Do not add a separate chooser annotation to GrammarExpr.choice. A branch is selected by its distinguishing terminal, whose framed bytes and src/dst identify the observable decision. Merge branches that resolve to identical observable byte languages, or add an observable discriminator."
    , "Define one TypedTaskRequirement per task. Transitions must reference typed state and message constructors."
    , "Define communicating sequential processes with TypedRequirementProcess or RequirementProcess for every actor participating in every task."
    , "Each task transition message must appear in one actor process sends list and one actor process receives list."
    , "Define RequiredProof obligations for the required proof modes: never, always, eventually, and possibly; include probability when the abstraction has a known exact or estimated probability mass for the predicate."
    , "Write quantified until formulas with the binary AU and EU operators, for example p AU q; do not use context-sensitive A[p U q] or E[p U q] wrapper notation."
    , "Use probabilities as probabilityNum/probabilityDen and dwell time as dwellMs."
    , "Interrogate the user until every requested result is identifiable: scenario boundaries, start/end pairing, work units, clock units, actor instances and populations, queue capacities, outage/recovery boundaries, observation windows, and whether each probability or distribution is observed, expected, or unknown. Do not invent missing values."
    , "From every sufficiently identified stream generate per-scenario interaction diagrams and state machines, XY line metrics, pie-chart histograms, uptime/reliability, throughput, and latency. Mark outputs indeterminate when required fields are absent."
    , "For synthetic similarity, first characterize the source with named exact reducers and distributions, generate a candidate stream, replay the same reducers, and accept only when every target is within its declared tolerance."
    , "Define RequirementSpec with actors, messages, tasks, grammars, processes, properties, requiredProofs, charts, and markdown."
    , "Define exactly one ActorResourceContract per actor with positive finite inboundCapacity, outboundCapacity, maxInFlight, and memoryBudgetBytes values."
    , "Model finite queues as blocking channels: send to full and blocking receive from empty make no progress; a distinct nonblocking tryReceive may return none and leave the actor runnable."
    , "Express information flow by calculating knowers(value, events) from initial knowledge, visible bytes, and derivation rules. Treat secrecy only as a comparison between that computed actor set and an allowed set."
    , "Expose workerRequirement or another named RequirementSpec, generatedRequirementsProto via include_str \"Requirements.proto\", aggregateGraphData, workerProtoFile or another proto export, all : List GeneratedRequirement, and validationReport."
    , "Implementation.lean imports Requirements, defines one ImplementationSpec referencing the RequirementSpec id, and covers every requirement actor and message exactly once."
    , "Do not generate JavaScript, HTML, JSON renderer data, or untyped string references for actors/messages/states."
    ]

def requirementsInterrogationChecklist : String :=
  joinWithNewline
    [ "LeanFM requirements interrogation checklist"
    , "1. What identifies a scenario, session, task, event, and concrete actor instance?"
    , "2. Which event kinds start and end each measurement, and does every end backpoint to its start?"
    , "3. What is the monotonic clock unit and observation window?"
    , "4. What is work: bytes moved, requests completed, money, or another additive unit?"
    , "5. Which actor populations, queue capacities, memory budgets, and in-flight limits apply?"
    , "6. Which alternatives are probabilistic, and are distributions observed, expected, or unknown?"
    , "7. Which events mean unavailable and recovered; what outage probability and expected MTTR are assumed?"
    , "8. Which client-experienced and server-aggregate throughput definitions are required?"
    , "9. Which latency percentiles, histogram bins, uptime, reliability, and XY groupings are required?"
    , "10. For generated similar scenarios, what metrics and relative tolerances define acceptance?"
    , "Required default outputs: interaction diagrams; state machines; XY line metrics; pie-chart histograms; uptime/reliability; throughput; latency."
    ]

end LeanFM
