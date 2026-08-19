import LeanFM.Protocol

namespace LeanFM

def joinWith (sep : String) : List String -> String
  | [] => ""
  | [x] => x
  | x :: xs => x ++ sep ++ joinWith sep xs

def actorName : Actor -> String
  | Actor.auth => "Auth"
  | Actor.db => "DB"
  | Actor.client => "Client"
  | Actor.gateway => "Gateway"
  | Actor.worker => "Worker"

def actorStateName : ActorState -> String
  | ActorState.idle => "idle"
  | ActorState.waiting => "waiting"
  | ActorState.queued => "queued"
  | ActorState.busy => "busy"
  | ActorState.sleeping => "sleeping"
  | ActorState.done => "done"
  | ActorState.failed => "failed"

def bytesName (bytes : List Nat) : String :=
  "[" ++ joinWith " " (bytes.map toString) ++ "]"

def transportName : Transport -> String
  | Transport.http => "http"
  | Transport.https => "https"

def taskName : TaskKind -> String
  | TaskKind.purchaseItem => "get_docs"
  | TaskKind.postReview => "post_review"
  | TaskKind.auth => "auth"

def activeTaskName : Option TaskKind -> String
  | some task => taskName task
  | none => "none"

def proofName : Option AuthProof -> String
  | some p => s!"proof({actorName p.issuedBy}->{actorName p.issuedTo}:{bytesName p.bytes})"
  | none => "no-proof"

def envelopeName (e : Envelope) : String :=
  s!"{taskName e.task} {actorName e.src}->{actorName e.dst} via={transportName e.transport} proto={e.proto.typeName} bytes={bytesName e.proto.bytes} payload={e.proto.summary} ts={e.ts}"

def optionEnvelopeName : Option Envelope -> String
  | some e => envelopeName e
  | none => "empty"

def stateName (s : Observation) : String :=
  s!"task={activeTaskName s.task}; auth={proofName s.proof}; Client={actorStateName s.client} q={s.clientQ}/{cap Actor.client} head={optionEnvelopeName s.clientMsg}; Gateway={actorStateName s.gateway} q={s.gatewayQ}/{cap Actor.gateway} head={optionEnvelopeName s.gatewayMsg}; Worker={actorStateName s.worker} q={s.workerQ}/{cap Actor.worker} head={optionEnvelopeName s.workerMsg}"

def compactHeadName : Option Envelope -> String
  | some e => e.proto.typeName
  | none => "-"

def authMark (s : Observation) : String :=
  if hasValidAuth s then "auth ok" else "no auth"

def compactStateName (s : Observation) : String :=
  s!"task={activeTaskName s.task}\\nC {actorStateName s.client} q={s.clientQ}/{cap Actor.client} h={compactHeadName s.clientMsg}\\nG {actorStateName s.gateway} q={s.gatewayQ}/{cap Actor.gateway} h={compactHeadName s.gatewayMsg}\\nW {actorStateName s.worker} q={s.workerQ}/{cap Actor.worker} h={compactHeadName s.workerMsg}\\n{authMark s}"

def authStateName (s : AuthObservation) : String :=
  s!"{proofName s.proof}; Auth={actorStateName s.auth} q={s.authQ}/{authCap Actor.auth}; DB={actorStateName s.db} q={s.dbQ}/{authCap Actor.db}"

def blockReasonName : BlockReason -> String
  | BlockReason.readEmpty => "sleep(read empty)"
  | BlockReason.writeFull => "sleep(write full)"

def turnName (t : Turn) : String :=
  let emitted :=
    match t.emitted with
    | some e => envelopeName e
    | none => "no message"
  let blocked :=
    match t.blocked with
    | some reason => s!" {blockReasonName reason}"
    | none => ""
  s!"schedule {actorName t.actor}: {emitted}{blocked}"

def compactTurnName (t : Turn) : String :=
  match t.emitted with
  | some e => s!"{actorName t.actor}: {e.proto.summary}"
  | none =>
      match t.blocked with
      | some reason => s!"{actorName t.actor}: {blockReasonName reason}"
      | none => s!"{actorName t.actor}: no message"

def transitionLine (t : Observation × Turn × Observation) : String :=
  s!"{stateName t.1} -- {turnName t.2.1} --> {stateName t.2.2}"

def authTransitionLine (t : AuthObservation × Turn × AuthObservation) : String :=
  s!"{authStateName t.1} -- {turnName t.2.1} --> {authStateName t.2.2}"

def dotLine (t : Observation × Turn × Observation) : String :=
  s!"  \"{stateName t.1}\" -> \"{stateName t.2.2}\" [label=\"{turnName t.2.1}\"];"

def compactDotLine (t : Observation × Turn × Observation) : String :=
  s!"  \"{compactStateName t.1}\" -> \"{compactStateName t.2.2}\" [label=\"{compactTurnName t.2.1}\"];"

def authTransitions : List (AuthObservation × Turn × AuthObservation) :=
  (authStates.map fun s =>
    (authChoices s).flatMap fun c =>
      (Choice.labeledSupport c).map fun step => (s, step.1, step.2)).flatten

def authDotLine (t : AuthObservation × Turn × AuthObservation) : String :=
  s!"  \"{authStateName t.1}\" -> \"{authStateName t.2.2}\" [label=\"{turnName t.2.1}\"];"

def graphStyle : List String :=
  [ "  rankdir=TB;"
  , "  graph [bgcolor=\"#111111\", pad=\"0.35\", nodesep=\"0.55\", ranksep=\"0.7\"];"
  , "  node [shape=box, style=\"rounded,filled\", fillcolor=\"black\", color=\"white\", fontcolor=\"white\", fontname=\"Arial\", fontsize=\"18\", margin=\"0.18,0.12\"];"
  , "  edge [fontname=\"Arial\", fontsize=\"14\", penwidth=\"2\", color=\"white\", fontcolor=\"white\"];"
  ]

def graphDot : String :=
  joinWith "\n" <|
    [ "digraph protocol {" ] ++
    graphStyle ++
    (states.map fun s => s!"  \"{compactStateName s}\";") ++
    (transitions.map compactDotLine) ++
    ["}"]

def clusterDot (clusterId label : String) (clusterStates : List Observation) : List String :=
  [ "  subgraph cluster_" ++ clusterId ++ " {"
  , s!"    label=\"{label}\";"
  , "    color=\"white\";"
  , "    fontcolor=\"white\";"
  , "    style=\"rounded\";"
  ] ++
  (clusterStates.map fun s => s!"    \"{compactStateName s}\";") ++
  ["  }"]

def unauthenticatedStates : List Observation :=
  [unauthenticatedInitial, unauthorized]

def noActiveTaskStates : List Observation :=
  [initial, succeeded, failed]

def getDocsActiveStates : List Observation :=
  [afterSubmit, afterDispatch, afterWorkerOk, afterWorkerFail, afterReply, afterReject]

def postReviewActiveStates : List Observation :=
  [reviewAfterSubmit, reviewAfterDispatch, reviewAfterWorkerOk, reviewAfterWorkerFail
  , reviewAfterReply, reviewAfterReject
  ]

def groupedGraphDot : String :=
  joinWith "\n" <|
    [ "digraph protocol {" ] ++
    graphStyle ++
    clusterDot "unauthenticated" "no auth proof" unauthenticatedStates ++
    clusterDot "idle_terminal" "no active task" noActiveTaskStates ++
    clusterDot "get_docs" "active task: get_docs" getDocsActiveStates ++
    clusterDot "post_review" "active task: post_review" postReviewActiveStates ++
    (transitions.map compactDotLine) ++
    ["}"]

def getDocsStates : List Observation :=
  [initial, afterSubmit, afterDispatch, afterWorkerOk, afterWorkerFail
  , afterReply, afterReject, succeeded, failed
  ]

def postReviewStates : List Observation :=
  [initial, reviewAfterSubmit, reviewAfterDispatch, reviewAfterWorkerOk, reviewAfterWorkerFail
  , reviewAfterReply, reviewAfterReject, succeeded, failed
  ]

def graphDotFor (name : String) (graphStates : List Observation) : String :=
  let graphTransitions := transitions.filter fun t =>
    graphStates.contains t.1 && graphStates.contains t.2.2
  joinWith "\n" <|
    [ "digraph " ++ name ++ " {" ] ++
    graphStyle ++
    (graphStates.map fun s => s!"  \"{compactStateName s}\";") ++
    (graphTransitions.map compactDotLine) ++
    ["}"]

def getDocsGraphDot : String :=
  graphDotFor "get_docs" getDocsStates

def postReviewGraphDot : String :=
  graphDotFor "post_review" postReviewStates

def authGraphDot : String :=
  joinWith "\n" <|
    [ "digraph auth {" ] ++
    graphStyle ++
    (authStates.map fun s => s!"  \"{authStateName s}\";") ++
    (authTransitions.map authDotLine) ++
    ["}"]

def assembledGraphDot : String :=
  joinWith "\n"
    [ "digraph assembled {"
    , "  rankdir=TB;"
    , "  graph [bgcolor=\"#111111\", pad=\"0.35\", nodesep=\"0.55\", ranksep=\"0.7\"];"
    , "  node [shape=box, style=\"rounded,filled\", fillcolor=\"black\", color=\"white\", fontcolor=\"white\", fontname=\"Arial\", fontsize=\"18\", margin=\"0.18,0.12\"];"
    , "  edge [fontname=\"Arial\", fontsize=\"14\", penwidth=\"2\", color=\"white\", fontcolor=\"white\"];"
    , s!"  AuthGroup [label=\"2 actor auth group\\nP(success)={fixed4Text authMetrics.successNum authMetrics.successDen}\\nE(latency)={fixed4Text authMetrics.latencyNum authMetrics.latencyDen}\\nthroughput={fixed4Text authMetrics.throughputNum authMetrics.throughputDen}\"];"
    , s!"  WorkerGroup [label=\"3 actor worker group\\nget_docs + post_review\\nP(success)={fixed4Text workerMetrics.successNum workerMetrics.successDen}\\nE(latency)={fixed4Text workerMetrics.latencyNum workerMetrics.latencyDen}\\nthroughput={fixed4Text workerMetrics.throughputNum workerMetrics.throughputDen}\"];"
    , s!"  Assembled [label=\"assembled system\\nP(success)={fixed4Text assembledMetrics.successNum assembledMetrics.successDen}\\nE(latency)={fixed4Text assembledMetrics.latencyNum assembledMetrics.latencyDen}\\nthroughput={fixed4Text assembledMetrics.throughputNum assembledMetrics.throughputDen}\"];"
    , "  AuthGroup -> WorkerGroup [label=\"on auth success\"];"
    , "  WorkerGroup -> Assembled [label=\"aggregate metrics\"];"
    , "}"
    ]

def taskGraphDot : String :=
  joinWith "\n"
    [ "digraph tasks {"
    , "  rankdir=TB;"
    , "  graph [bgcolor=\"#111111\", pad=\"0.35\", nodesep=\"0.55\", ranksep=\"0.7\"];"
    , "  node [shape=box, style=\"rounded,filled\", fillcolor=\"black\", color=\"white\", fontcolor=\"white\", fontname=\"Arial\", fontsize=\"18\", margin=\"0.18,0.12\"];"
    , "  edge [fontname=\"Arial\", fontsize=\"14\", penwidth=\"2\", color=\"white\", fontcolor=\"white\"];"
    , s!"  Purchase [label=\"get_docs\\nP(success)={fixed4Text purchaseMetrics.successNum purchaseMetrics.successDen}\\nE(latency)={fixed4Text purchaseMetrics.latencyNum purchaseMetrics.latencyDen}\\nthroughput={fixed4Text purchaseMetrics.throughputNum purchaseMetrics.throughputDen}\"];"
    , s!"  Review [label=\"post_review\\nP(success)={fixed4Text reviewMetrics.successNum reviewMetrics.successDen}\\nE(latency)={fixed4Text reviewMetrics.latencyNum reviewMetrics.latencyDen}\\nthroughput={fixed4Text reviewMetrics.throughputNum reviewMetrics.throughputDen}\"];"
    , "  Actors [label=\"shared actors\\nClient, Gateway, Worker\"];"
    , "  Purchase -> Actors [label=\"same actor group\"];"
    , "  Review -> Actors [label=\"same actor group\"];"
    , "}"
    ]

def weightedLine (label : String) (w : Weighted Observation) : String :=
  s!"    {label} [weight={w.weight}, dwell={w.dwell}] -> {stateName w.value}"

def choiceLines (s : Observation) (choice : Choice Observation Turn) : List String :=
  match choice with
  | Choice.action t dwell s' =>
      [s!"  {stateName s} action {turnName t} [dwell={dwell}] -> {stateName s'}"]
  | Choice.chance t outcomes =>
      s!"  {stateName s} chance after {turnName t}:" ::
        outcomes.map (weightedLine (turnName t))
  | Choice.chanceEvents outcomes =>
      s!"  {stateName s} chance:" ::
        outcomes.map fun outcome =>
          s!"    {turnName outcome.value.1} [weight={outcome.weight}, dwell={outcome.dwell}] -> {stateName outcome.value.2}"

def ctlLine (name : String) (formula : CTL Observation) : String :=
  let result := CTL.holds successors initial formula
  s!"{name}: {result}"

def ctlLineFrom (start : Observation) (name : String) (formula : CTL Observation) : String :=
  let result := CTL.holds successors start formula
  s!"{name}: {result}"

def distributionLine (bucket : Nat × Nat) : String :=
  s!"  queue length {bucket.1}: {ratioText bucket.2 expectedLatencyNumerator} = {fixed4Text bucket.2 expectedLatencyNumerator}"

def traceEventName (t : Turn) : String :=
  match t.emitted with
  | some e => s!"src={actorName e.src}, dst={actorName e.dst}, payload=\"{e.proto.summary}\", ts={e.ts}"
  | none =>
      match t.blocked with
      | some reason => s!"actor={actorName t.actor}, {blockReasonName reason}"
      | none => s!"actor={actorName t.actor}, no message"

def trafficTrace : List Turn -> List String
  | [] => []
  | t :: rest =>
      match t.emitted with
      | some e =>
          if t.actor = e.src then
            traceEventName t :: trafficTrace rest
          else
            trafficTrace rest
      | none => trafficTrace rest

def traceName (trace : List Turn) : String :=
  joinWith "; " (trafficTrace trace)

def terminalLine (path : PathStats Observation Turn) : String :=
  s!"  p={path.mass}/{path.scale}, elapsed={path.elapsed}, state={stateName path.state}, trace=[{traceName path.trace}]"

def metricLine (name : String) (num den : Nat) : String :=
  s!"{name}: {ratioText num den} = {fixed4Text num den}"

def metricsLines (label : String) (m : Metrics) : List String :=
  [ metricLine s!"{label} success probability" m.successNum m.successDen
  , metricLine s!"{label} expected latency" m.latencyNum m.latencyDen
  , metricLine s!"{label} throughput" m.throughputNum m.throughputDen
  ]

def taskListName (tasks : List TaskKind) : String :=
  joinWith ", " (tasks.map taskName)

def actorSpecLine (spec : ActorSpec) : String :=
  s!"  {actorName spec.actor}: queueCap={spec.queueCap}, tasks=[{taskListName spec.tasks}]"

def messageListName (messages : List Envelope) : String :=
  joinWith ", " (messages.map envelopeName)

def taskMachineLine (machine : TaskMachine) : String :=
  s!"  {actorName machine.owner}.{taskName machine.task}: accepts=[{messageListName machine.accepts}], emits=[{messageListName machine.emits}]"

def textReport : String :=
  joinWith "\n" <|
    ["Two-actor auth group grammar"] ++
    (authGrammar.map fun e => s!"  {envelopeName e}") ++
    ["  artifact: " ++ proofName (some loginProof)] ++
    ["", "Three-actor get_docs grammar"] ++
    (grammar.map fun e => s!"  {envelopeName e}") ++
    ["", "Three-actor post_review grammar"] ++
    (reviewGrammar.map fun e => s!"  {envelopeName e}") ++
    ["", "Assembled system grammar"] ++
    (assembledGrammar.map fun e => s!"  {envelopeName e}") ++
    ["", "World actor/task composition"] ++
    (workerWorld.actors.map actorSpecLine) ++
    ["", "Task machines selected from queued messages"] ++
    (workerWorld.tasks.map taskMachineLine) ++
    ["", "Observable actor-state transitions"] ++
    (transitions.map fun t => s!"  {transitionLine t}") ++
    ["", "MDP choices"] ++
    (states.flatMap fun s => (choices s).flatMap (choiceLines s)) ++
    ["", "Time-weighted queue length distribution under successPolicy"] ++
    (queueLengthTimeDistribution.map distributionLine) ++
    ["", "Global visible terminal traces under successPolicy"] ++
    (terminalStats.map terminalLine) ++
    ["", "Expected metrics under successPolicy"
    , metricLine "expected latency" expectedLatencyNumerator expectedLatencyDenominator
    , metricLine "success probability" successMass terminalMass
    , metricLine "throughput" throughputNumerator throughputDenominator
    , "", "Component and assembled metrics"] ++
    metricsLines "auth group" authMetrics ++
    metricsLines "get_docs task" purchaseMetrics ++
    metricsLines "post_review task" reviewMetrics ++
    metricsLines "worker group" workerMetrics ++
    metricsLines "assembled system" assembledMetrics ++
    ["", "Graphviz DOT", graphDot
    , "", "CTL from initial observation"
    , ctlLine "AF success (all paths eventually succeed)" mustEventuallySucceed
    , ctlLine "AG !fail   (all reachable observations avoid failure)" neverFails
    , ctlLine "EF fail    (some path can fail)" mayFail
    , ctlLine "AG capacity (all reachable queues stay within capacity)" queuesStayWithinCapacity
    , ctlLine "AG no success without auth proof" noSuccessWithoutAuth
    , ctlLine "AG queued heads select known actor tasks" actorQueuesSelectKnownTasks
    , ctlLine "AG terminal states clean up active task" terminalTasksAreCleanedUp
    , "", "CTL from unauthenticated task attempt"
    , ctlLineFrom unauthenticatedInitial "EX unauthorized (client task step is rejected)" unauthenticatedAttemptCanBeRejected
    , ctlLineFrom unauthenticatedInitial "AG no success without auth proof" noSuccessWithoutAuth
    ]

def trafficAnimation : String :=
  "<section><h2>Traffic Animation</h2><div class=\"canvasPanel\"><canvas id=\"traffic\" width=\"900\" height=\"360\"></canvas><ol id=\"trafficTrace\"></ol></div></section>" ++
  "<script>" ++
  "const canvas=document.getElementById('traffic');const ctx=canvas.getContext('2d');" ++
  "const traceEl=document.getElementById('trafficTrace');" ++
  "const actors={Client:{x:120,y:95},Gateway:{x:450,y:95},Worker:{x:780,y:95}};" ++
  "const events=[" ++
  "{src:'Client',dst:'Gateway',payload:'GET /docs/index.html',proto:'Docs.GetRequest',ts:1}," ++
  "{src:'Gateway',dst:'Worker',payload:'fetch /docs/index.html',proto:'Docs.FetchCommand',ts:3}," ++
  "{src:'Worker',dst:'Gateway',payload:'200 /docs/index.html',proto:'Docs.FetchResult',ts:7}," ++
  "{src:'Gateway',dst:'Client',payload:'200 /docs/index.html',proto:'Docs.GetResponse',ts:8}," ++
  "{src:'Client',dst:'Gateway',payload:'POST /reviews',proto:'Reviews.PostRequest',ts:1}," ++
  "{src:'Gateway',dst:'Worker',payload:'moderate review',proto:'Reviews.ModerateCommand',ts:2}," ++
  "{src:'Worker',dst:'Gateway',payload:'review accepted',proto:'Reviews.ModerationResult',ts:5}," ++
  "{src:'Gateway',dst:'Client',payload:'201 /reviews',proto:'Reviews.PostResponse',ts:6}" ++
  "];" ++
  "function drawActor(name,a){ctx.fillStyle='#000';ctx.strokeStyle='#fff';ctx.lineWidth=2;ctx.fillRect(a.x-70,a.y-36,140,72);ctx.strokeRect(a.x-70,a.y-36,140,72);ctx.fillStyle='#fff';ctx.font='18px sans-serif';ctx.textAlign='center';ctx.fillText(name,a.x,a.y+6);}" ++
  "function draw(){const w=canvas.width,h=canvas.height;ctx.fillStyle='#111';ctx.fillRect(0,0,w,h);Object.entries(actors).forEach(([n,a])=>drawActor(n,a));ctx.strokeStyle='#666';ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(120,180);ctx.lineTo(780,180);ctx.stroke();const now=performance.now();const span=1500;const i=Math.floor(now/span)%events.length;const p=(now%span)/span;const e=events[i];const a=actors[e.src],b=actors[e.dst];const x=a.x+(b.x-a.x)*p;const y=180+Math.sin(p*Math.PI)*-42;ctx.strokeStyle='#93c5fd';ctx.lineWidth=3;ctx.beginPath();ctx.moveTo(a.x,180);ctx.lineTo(b.x,180);ctx.stroke();ctx.fillStyle='#f8f8f8';ctx.beginPath();ctx.arc(x,y,9,0,Math.PI*2);ctx.fill();ctx.font='16px sans-serif';ctx.textAlign='center';ctx.fillText(e.proto,x,250);ctx.fillText(e.payload,x,276);ctx.fillText(e.src+' -> '+e.dst+'  ts='+e.ts,x,302);traceEl.innerHTML=events.map((ev,j)=>'<li'+(j===i?' class=\"active\"':'')+'>'+ev.src+' -> '+ev.dst+' | '+ev.payload+' | ts='+ev.ts+'</li>').join('');requestAnimationFrame(draw);}draw();" ++
  "</script>"

def aggregateGraphAnimation : String :=
  "<section><h2>Aggregate Graph</h2><div class=\"controlPanel\"><label>Group by <select id=\"groupBy\"><option value=\"task\">active task</option><option value=\"auth\">auth proof</option><option value=\"terminal\">terminal</option><option value=\"queue\">queue length</option></select></label></div><div class=\"canvasPanel\"><canvas id=\"aggGraph\" width=\"1000\" height=\"520\"></canvas><div id=\"aggInfo\"></div></div></section>" ++
  "<script>" ++
  "const graphCanvas=document.getElementById('aggGraph');const gctx=graphCanvas.getContext('2d');const groupBy=document.getElementById('groupBy');const aggInfo=document.getElementById('aggInfo');" ++
  "const gNodes=[" ++
  "{id:'unauth_idle',task:'none',auth:'no auth',terminal:false,q:0,label:'no auth idle'}," ++
  "{id:'unauthorized',task:'none',auth:'no auth',terminal:true,q:0,label:'unauthorized'}," ++
  "{id:'idle',task:'none',auth:'auth ok',terminal:false,q:0,label:'ready'}," ++
  "{id:'gd_submit',task:'get_docs',auth:'auth ok',terminal:false,q:1,label:'GET queued at Gateway'}," ++
  "{id:'gd_worker',task:'get_docs',auth:'auth ok',terminal:false,q:1,label:'fetch queued at Worker'}," ++
  "{id:'gd_ok',task:'get_docs',auth:'auth ok',terminal:false,q:1,label:'200 queued at Gateway'}," ++
  "{id:'gd_fail',task:'get_docs',auth:'auth ok',terminal:false,q:1,label:'404 queued at Gateway'}," ++
  "{id:'gd_reply',task:'get_docs',auth:'auth ok',terminal:false,q:1,label:'200 queued at Client'}," ++
  "{id:'gd_reject',task:'get_docs',auth:'auth ok',terminal:false,q:1,label:'401 queued at Client'}," ++
  "{id:'done',task:'none',auth:'auth ok',terminal:true,q:0,label:'done cleaned'}," ++
  "{id:'failed',task:'none',auth:'auth ok',terminal:true,q:0,label:'failed cleaned'}," ++
  "{id:'rv_submit',task:'post_review',auth:'auth ok',terminal:false,q:1,label:'review queued at Gateway'}," ++
  "{id:'rv_worker',task:'post_review',auth:'auth ok',terminal:false,q:1,label:'moderate queued at Worker'}," ++
  "{id:'rv_ok',task:'post_review',auth:'auth ok',terminal:false,q:1,label:'201 queued at Gateway'}," ++
  "{id:'rv_fail',task:'post_review',auth:'auth ok',terminal:false,q:1,label:'reject queued at Gateway'}," ++
  "{id:'rv_reply',task:'post_review',auth:'auth ok',terminal:false,q:1,label:'201 queued at Client'}," ++
  "{id:'rv_reject',task:'post_review',auth:'auth ok',terminal:false,q:1,label:'400 queued at Client'}" ++
  "];" ++
  "const gEdges=[['unauth_idle','unauthorized'],['idle','gd_submit'],['idle','rv_submit'],['gd_submit','gd_worker'],['gd_submit','gd_reject'],['gd_worker','gd_ok'],['gd_worker','gd_fail'],['gd_ok','gd_reply'],['gd_fail','gd_reject'],['gd_reply','done'],['gd_reject','failed'],['rv_submit','rv_worker'],['rv_submit','rv_reject'],['rv_worker','rv_ok'],['rv_worker','rv_fail'],['rv_ok','rv_reply'],['rv_fail','rv_reject'],['rv_reply','done'],['rv_reject','failed']];" ++
  "let openGroups=new Set();let pos={};let hit=[];" ++
  "function bucket(n){const k=groupBy.value;if(k==='task')return n.task;if(k==='auth')return n.auth;if(k==='terminal')return n.terminal?'terminal':'nonterminal';return 'q='+n.q;}" ++
  "function groups(){const m=new Map();for(const n of gNodes){const b=bucket(n);if(!m.has(b))m.set(b,[]);m.get(b).push(n);}return [...m.entries()].map(([key,nodes])=>({key,nodes}));}" ++
  "function targetLayout(){const gs=groups();const out={};const visible=[];const cols=Math.min(3,gs.length);const cellW=graphCanvas.width/(cols+1);const rowH=170;gs.forEach((g,i)=>{const cx=cellW*((i%cols)+1),cy=95+Math.floor(i/cols)*rowH;out['group:'+g.key]={x:cx,y:cy};visible.push({type:'group',key:g.key,x:cx,y:cy,count:g.nodes.length});if(openGroups.has(g.key)){g.nodes.forEach((n,j)=>{const a=(Math.PI*2*j)/Math.max(1,g.nodes.length);out[n.id]={x:cx+95*Math.cos(a),y:cy+72*Math.sin(a)+68};visible.push({type:'node',node:n});});}});return{out,visible};}" ++
  "function endpoint(id,t){const n=gNodes.find(x=>x.id===id);const b=bucket(n);return openGroups.has(b)?(pos[id]||t.out[id]):(pos['group:'+b]||t.out['group:'+b]);}" ++
  "function drawAgg(){const t=targetLayout();for(const k in t.out){const p=pos[k]||t.out[k];pos[k]={x:p.x+(t.out[k].x-p.x)*0.14,y:p.y+(t.out[k].y-p.y)*0.14};}gctx.fillStyle='#111';gctx.fillRect(0,0,graphCanvas.width,graphCanvas.height);hit=[];gctx.strokeStyle='#555';gctx.lineWidth=1.5;for(const e of gEdges){const a=endpoint(e[0],t),b=endpoint(e[1],t);if(!a||!b)continue;gctx.beginPath();gctx.moveTo(a.x,a.y);gctx.lineTo(b.x,b.y);gctx.stroke();}for(const item of t.visible){if(item.type==='group'){const p=pos['group:'+item.key];gctx.fillStyle=openGroups.has(item.key)?'#111827':'#000';gctx.strokeStyle='#fff';gctx.lineWidth=2;gctx.fillRect(p.x-82,p.y-34,164,68);gctx.strokeRect(p.x-82,p.y-34,164,68);gctx.fillStyle='#fff';gctx.font='16px sans-serif';gctx.textAlign='center';gctx.fillText(item.key,p.x,p.y-5);gctx.fillText(item.count+' states '+(openGroups.has(item.key)?'open':'closed'),p.x,p.y+18);hit.push({kind:'group',key:item.key,x:p.x-82,y:p.y-34,w:164,h:68});}else{const p=pos[item.node.id];if(!p)continue;gctx.fillStyle='#0b0b0b';gctx.strokeStyle='#93c5fd';gctx.lineWidth=1.5;gctx.beginPath();gctx.arc(p.x,p.y,27,0,Math.PI*2);gctx.fill();gctx.stroke();gctx.fillStyle='#fff';gctx.font='11px sans-serif';gctx.textAlign='center';gctx.fillText(item.node.label,p.x,p.y+4);}}aggInfo.innerHTML='<p>Click a bucket to open or close it. The selector simulates a property query that buckets states into a hash table.</p><ul>'+groups().map(g=>'<li>'+g.key+': '+g.nodes.length+' states</li>').join('')+'</ul>';requestAnimationFrame(drawAgg);}graphCanvas.addEventListener('click',ev=>{const r=graphCanvas.getBoundingClientRect();const x=(ev.clientX-r.left)*graphCanvas.width/r.width,y=(ev.clientY-r.top)*graphCanvas.height/r.height;for(const h of hit){if(x>=h.x&&x<=h.x+h.w&&y>=h.y&&y<=h.y+h.h){openGroups.has(h.key)?openGroups.delete(h.key):openGroups.add(h.key);break;}}});groupBy.addEventListener('change',()=>{openGroups.clear();});drawAgg();" ++
  "</script>"

def htmlPage : String :=
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>LeanFM</title>" ++
  "<meta name=\"color-scheme\" content=\"dark only\">" ++
  "<style>html,body{background:#111;color:#f8f8f8;color-scheme:dark only;forced-color-adjust:none}body{font-family:system-ui,sans-serif;margin:2rem;line-height:1.4}a{color:#93c5fd}pre{background:#050505;color:#f8f8f8;border:1px solid #333;padding:1rem;overflow:auto}code{font-family:ui-monospace,monospace}details{border:1px solid #444;margin:.75rem 0 1rem;background:#090909}summary{cursor:pointer;padding:.75rem 1rem;font-weight:700}.diagram{background:#111;border-top:1px solid #333;margin:0;padding:1rem;overflow:auto;min-height:220px;forced-color-adjust:none}.diagram img{display:block;max-width:100%;height:auto;background:#111;forced-color-adjust:none}.controlPanel{margin:.5rem 0 1rem}.controlPanel select{background:#000;color:#fff;border:1px solid #666;padding:.35rem}.canvasPanel{display:grid;grid-template-columns:minmax(320px,900px) minmax(260px,1fr);gap:1rem;align-items:start}.canvasPanel canvas{width:100%;height:auto;background:#111;border:1px solid #555}.canvasPanel ol,.canvasPanel ul{margin:0;padding-left:1.5rem;font-family:ui-monospace,monospace}.canvasPanel li{padding:.2rem .35rem}.canvasPanel li.active{background:#1d4ed8;color:#fff}</style>" ++
  "</head><body><h1>LeanFM</h1><p>Lean-native model of message-passing processes.</p>" ++
  "<p><a href=\"/metrics\">metrics</a> | <a href=\"/auth.dot\">auth.dot</a> | <a href=\"/graph.dot\">worker.dot</a> | <a href=\"/get_docs.dot\">get_docs.dot</a> | <a href=\"/post_review.dot\">post_review.dot</a> | <a href=\"/tasks.dot\">tasks.dot</a> | <a href=\"/assembled.dot\">assembled.dot</a></p>" ++
  trafficAnimation ++
  aggregateGraphAnimation ++
  "<details open><summary>Auth Group</summary><div class=\"diagram\"><img src=\"/diagrams/auth.png?v=4\" alt=\"Auth group state graph\"></div></details>" ++
  "<details><summary>Worker Group Overview</summary><div class=\"diagram\"><img src=\"/diagrams/worker.png?v=5\" alt=\"Worker group state graph\"></div></details>" ++
  "<details><summary>get_docs Task</summary><div class=\"diagram\"><img src=\"/diagrams/get_docs.png?v=5\" alt=\"get_docs task state graph\"></div></details>" ++
  "<details><summary>post_review Task</summary><div class=\"diagram\"><img src=\"/diagrams/post_review.png?v=5\" alt=\"post_review task state graph\"></div></details>" ++
  "<details open><summary>Task Conversations</summary><div class=\"diagram\"><img src=\"/diagrams/tasks.png?v=4\" alt=\"Task conversations graph\"></div></details>" ++
  "<details open><summary>Assembled System</summary><div class=\"diagram\"><img src=\"/diagrams/assembled.png?v=4\" alt=\"Assembled system graph\"></div></details>" ++
  "<pre>" ++ textReport ++ "</pre></body></html>"

end LeanFM
