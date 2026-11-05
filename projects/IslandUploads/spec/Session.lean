import LeanFM.Session

/-!
# IslandUploads as session types

The tasks of `Requirements.lean` as global types, with the physics of their channels and the
deployment tree: `shard1` and its worker in island `us`, `shard2` and its worker in island `eu`,
browsers outside. Every `#guard` runs when the file is elaborated.

Run from the LeanFM root: `lake env lean projects/IslandUploads/spec/Session.lean`.
-/

namespace Project.Session
open LeanFM.Session

/-- `api1` is a service mounted at `/apis/db` in island `us`: an internal HTTP host that only the
door, `shard1`'s `ingressHttps`, forwards to. -/
inductive Role | browser | shard1 | shard2 | worker1 | worker2 | api1
  deriving DecidableEq, Repr, Inhabited

instance : ToString Role := ⟨fun
  | .browser => "Browser" | .shard1 => "shard1" | .shard2 => "shard2"
  | .worker1 => "worker1" | .worker2 => "worker2" | .api1 => "api1"⟩

/-! ## Vocabulary (payloads are in Requirements.proto; only what guards read is typed here) -/

structure UploadStart    where requestId : String deriving TypeName
structure UploadStarted  where
  requestId : String
  offset : Nat
  deriving TypeName
structure UploadPart     where offset : Nat deriving TypeName
structure UploadPartAck  where offset : Nat deriving TypeName
structure UploadFinish   where deriving TypeName
structure UploadResponse where requestId : String deriving TypeName
structure UploadRejected where
  status : Nat
  offset : Nat
  deriving TypeName
structure UpdateRequest  where
  requestId : String
  id : Nat
  prevDts : List Nat
  deriving TypeName
structure UpdateResponse where
  requestId : String
  id : Nat
  prevDts : List Nat
  deriving TypeName
structure UpdateRejected where deriving TypeName
structure FeedRequest    where afterVisibleDt : Nat deriving TypeName
structure FeedResponse   where lastVisibleDt : Nat deriving TypeName
structure DownloadRequest where deriving TypeName
structure DownloadResponse where deriving TypeName
structure AccessDenied   where status : Nat deriving TypeName
structure RangeNotSatisfiable where deriving TypeName
structure IHaveRequest   where deriving TypeName
structure IHaveResponse  where deriving TypeName
structure RecordsRequest where
  afterVisibleDt : Nat
  deriving TypeName
structure RecordsResponse where
  lastVisibleDt : Nat
  more : Bool
  deriving TypeName
structure BlobRequest    where urgent : Bool deriving TypeName
structure BlobResponse   where deriving TypeName
structure BlobMissing    where deriving TypeName
structure JobRequest     where job : String deriving TypeName
structure JobResult      where job : String deriving TypeName
structure JobFailed      where deriving TypeName
structure ApiRequest     where
  mount : String
  task : String
  deriving TypeName
structure ApiForward     where task : String deriving TypeName
structure ApiReply       where status : Nat deriving TypeName
structure ApiResponse    where status : Nat deriving TypeName
structure WsUpgrade      where mount : String deriving TypeName
structure WsAccepted     where deriving TypeName
structure FrameUp        where deriving TypeName
structure FrameDown      where deriving TypeName
structure CloseUp        where deriving TypeName
structure CloseDown      where deriving TypeName

/-! ## Global types -/

/-- A write never involves another shard. Content arrives in parts: start empty, append, finish.
A rejected part names the offset the shard holds, and the browser resends from there. -/
protocol Upload (Browser, Shard) {
  u: UploadStart from Browser to Shard;
  choice {
    o: UploadStarted from Shard to Browser cause u where o.requestId = u.requestId ∧ o.offset = 0;
    rec Parts {
      choice {
        p: UploadPart from Browser to Shard;
        choice {
          a: UploadPartAck from Shard to Browser cause p where a.offset > p.offset;
          continue Parts;
        } or {
          x: UploadRejected from Shard to Browser cause p where x.status = 409;
          continue Parts;
        }
      } or {
        f: UploadFinish from Browser to Shard;
        choice {
          r: UploadResponse from Shard to Browser cause f where r.requestId = u.requestId;
        } or {
          UploadRejected from Shard to Browser cause f;
        }
      }
    }
  } or {
    UploadRejected from Shard to Browser cause u;
  }
}

protocol Update (Browser, Shard) {
  u: UpdateRequest from Browser to Shard;
  choice {
    r: UpdateResponse from Shard to Browser cause u where r.prevDts = u.prevDts ∧ r.id = u.id;
  } or {
    UpdateRejected from Shard to Browser cause u;
  }
}

/-- One page of the local feed; the browser sends the next request from the page's cursor. -/
protocol Feed (Browser, Shard) {
  f: FeedRequest from Browser to Shard;
  choice {
    p: FeedResponse from Shard to Browser cause f where p.lastVisibleDt ≥ f.afterVisibleDt;
  } or {
    a: AccessDenied from Shard to Browser cause f where a.status = 401;
  }
}

/-- A download is checked against policy, then served from the local blob: a visible record
always has its blob here. -/
protocol Download (Browser, Shard) {
  d: DownloadRequest from Browser to Shard;
  choice {
    a: AccessDenied from Shard to Browser cause d where a.status = 401 ∨ a.status = 404;
  } or {
    DownloadResponse from Shard to Browser cause d;
  } or {
    RangeNotSatisfiable from Shard to Browser cause d;
  }
}

/-- The opening of a round of record anti-entropy: the caller's cursor into the peer's feed, and how
far that feed now reaches. -/
protocol Replicate (Shard, Peer) {
  i: IHaveRequest from Shard to Peer;
     IHaveResponse from Peer to Shard cause i;
}

/-- One page of the peer's feed past the caller's cursor, in the peer's `visible_dt` order. Every page
is its own session: the peer answers each request on its own and never needs to know when the
puller stops. Whether to ask for another page is the puller's decision, from the `more` flag. A timeout is physics (the channel's
deadline), not a branch of the type. -/
protocol PullPage (Shard, Peer) {
  q: RecordsRequest from Shard to Peer;
  p: RecordsResponse from Peer to Shard cause q where p.lastVisibleDt ≥ q.afterVisibleDt;
}

/-- One range of a record's blob, pulled by an import lane. Every range is its own session; the
lane decides whether to ask for the next one, and the record becomes visible only after the last. -/
protocol ImportRange (Shard, Peer) {
  b: BlobRequest from Shard to Peer where b.urgent = false;
  choice {
    BlobResponse from Peer to Shard cause b;
  } or {
    BlobMissing from Peer to Shard cause b;
  }
}

/-- A blob created on this shard gets its jobs; the outputs come back as new files. -/
protocol Derive (Shard, Worker) {
  j: JobRequest from Shard to Worker;
  choice {
    r: JobResult from Worker to Shard cause j where r.job = j.job;
  } or {
    JobFailed from Worker to Shard cause j;
  }
}

/-- The door forwards: `GET /apis/$x/$task` from a browser becomes `GET /$task` on the host
mounted at `$x`, and its answer goes back the way it came. The door verifies the token and runs
the walk for the path first; a denied or unmounted path is answered like a missing file. A host
that does not answer is the channel's timeout (physics), answered by the door with 502 and 504.
A big response is still one response whose body streams; its channel's `close` is handled. -/
protocol Forward (Browser, Door, Host) {
  r: ApiRequest from Browser to Door;
  choice {
    f: ApiForward from Door to Host cause r where f.task = r.task;
    a: ApiReply from Host to Door cause f;
    p: ApiResponse from Door to Browser cause r where p.status = a.status;
  } or {
    d: AccessDenied from Door to Browser cause r where d.status = 401 ∨ d.status = 404;
  }
}

/-- A websocket through the door. After the upgrade is accepted both ways, the two directions are
independent: either end sends frames until it closes its direction. -/
protocol Socket (Browser, Door, Host) {
  u: WsUpgrade from Browser to Door;
  choice {
    g: WsUpgrade from Door to Host cause u where g.mount = u.mount;
    a: WsAccepted from Host to Door cause g;
    WsAccepted from Door to Browser cause u;
    par {
      rec Up {
        choice {
          FrameUp from Browser to Door;
          FrameUp from Door to Host;
          continue Up;
        } or {
          CloseUp from Browser to Door;
          CloseUp from Door to Host;
        }
      }
    } and {
      rec Down {
        choice {
          FrameDown from Host to Door;
          FrameDown from Door to Browser;
          continue Down;
        } or {
          CloseDown from Host to Door;
          CloseDown from Door to Browser;
        }
      }
    }
  } or {
    d: AccessDenied from Door to Browser cause u where d.status = 401 ∨ d.status = 404;
  }
}

def upload := Upload Role.browser Role.shard1
def update := Update Role.browser Role.shard1
def feed := Feed Role.browser Role.shard1
def download := Download Role.browser Role.shard1
def replicate := Replicate Role.shard1 Role.shard2
def pullPage := PullPage Role.shard1 Role.shard2
def importRange := ImportRange Role.shard1 Role.shard2
def derive := Derive Role.shard1 Role.worker1
def forward := Forward Role.browser Role.shard1 Role.api1
def socket := Socket Role.browser Role.shard1 Role.api1

def all : List (String × Global Role × List Role) :=
  [ ("upload", upload, [.browser, .shard1]), ("update", update, [.browser, .shard1])
  , ("feed", feed, [.browser, .shard1]), ("download", download, [.browser, .shard1])
  , ("replicate", replicate, [.shard1, .shard2]), ("pullPage", pullPage, [.shard1, .shard2])
  , ("importRange", importRange, [.shard1, .shard2])
  , ("derive", derive, [.shard1, .worker1])
  , ("forward", forward, [.browser, .shard1, .api1]), ("socket", socket, [.browser, .shard1, .api1]) ]

#guard all.all (fun (_, g, rs) => g.issues rs == [])

/-! ## HTTP discipline: every response goes back to the role that asked -/

def isHttp : Role → Role → Bool
  | .worker1, _ | _, .worker1 | .worker2, _ | _, .worker2 => false
  | _, _ => true

/-- Browsers call shards; shards call each other; the door calls the hosts mounted behind it.
Nobody calls a browser, and a host calls nobody. -/
def mayCall : Role → Role → Bool
  | .browser, .shard1 | .browser, .shard2 | .shard1, .shard2 | .shard2, .shard1 | .shard1, .api1 => true
  | _, _ => false

-- After its upgrade a websocket is a stream, not HTTP: frames are not requests. Every other
-- protocol is checked as HTTP, the forwarded call included: request, forward, reply, response.
#guard (all.filter (·.1 != "socket")).all (fun (_, g, _) => g.httpCuts isHttp mayCall == [])
-- And the checks bite. The websocket fails the HTTP check, which is why it is checked as a stream:
#guard socket.httpCuts isHttp mayCall != []

/-- A host that answers the browser itself, skipping the door: the browser never called the host,
so that response is a cut. -/
protocol ForwardDirect (Browser, Door, Host) {
  r: ApiRequest from Browser to Door;
  f: ApiForward from Door to Host cause r;
  ApiResponse from Host to Browser cause r;
}

#guard (ForwardDirect Role.browser Role.shard1 Role.api1).httpCuts isHttp mayCall != []

/-! ## Physics -/

def physics : Physics Role :=
  { channels :=
      [ (.browser, .shard1, http), (.shard1, .browser, http)
      , (.shard1, .shard2, http), (.shard2, .shard1, http)
      , (.shard1, .worker1, reliable 32), (.worker1, .shard1, reliable 32)
      , (.shard1, .api1, http), (.api1, .shard1, http) ] }

/-- What each channel's protocol handles. `request_id` makes a retried upload idempotent; pages
and records are idempotent by `(id, dt)`; a closed or rejected call is retried. -/
def handles : List (Role × Role × List Condition) :=
  let httpAll : List Condition := [.timeout, .duplicate, .reorder, .reject, .close]
  [ (.browser, .shard1, httpAll), (.shard1, .browser, httpAll)
  , (.shard1, .shard2, httpAll), (.shard2, .shard1, httpAll)
  , (.shard1, .api1, httpAll), (.api1, .shard1, httpAll) ]

def specs : List (Spec Role) :=
  all.map (fun (_, g, rs) => { global := g, roles := rs, physics, handles })

#guard specs.all (fun s => s.issues == [])

/-! ## The deployment: two islands -/

open Node in
def deployment : Topology Role :=
  { world := [
      outside [ .actor .browser [] ],
      island "us" [ datacenter "dc1" [ machine "m1" [
        .actor .shard1 [ ingress "https" .ingressHttps, peering "api" .api ],
        .actor .worker1 [ «local» "jobs" .queue ] ],
        machine "m2" [ .actor .api1 [ internal "http" .api ] ] ] ],
      island "eu" [ datacenter "dc1" [ machine "m1" [
        .actor .shard2 [ ingress "https" .ingressHttps, peering "api" .api ],
        .actor .worker2 [ «local» "jobs" .queue ] ] ] ] ] }

def conditionsTo (src : Role) (name : String) : List String :=
  ((deployment.find name).map (fun p => (deployment.channel src p).conditions.map (·.name))).getD ["unreachable"]

def reach (src : Role) (name : String) : Bool :=
  ((deployment.find name).map (deployment.reachable src ·)).getD false

-- Browsers reach shards only through ingress; shards reach each other through peering.
#guard reach .browser "us.shard1.ingress.https" && !reach .browser "us.shard1.peering.api"
#guard reach .shard2 "us.shard1.peering.api"
-- A worker is local to its shard's machine: the other island's shard cannot reach it.
#guard reach .shard1 "us.worker1.local.jobs" && !reach .shard2 "us.worker1.local.jobs"
-- A mounted host is internal: the door reaches it, a browser and the other island cannot.
#guard reach .shard1 "us.api1.internal.http" && !reach .browser "us.api1.internal.http"
#guard !reach .shard2 "us.api1.internal.http"
-- Across islands the peering channel also surfaces partition; the protocol must handle it.
#guard conditionsTo .shard2 "us.shard1.peering.api" == ["duplicate", "reject", "close", "timeout", "partition"]

/-- With the deployment applied, the shard-to-shard channels surface partition, and the handled
list above does not mention it. The anti-entropy design is the answer: writes never wait, the
timer retries, and convergence after repair is checked by the MCP server in `Islands.lean`. -/
def unhandled : List String :=
  (conditionsTo .shard2 "us.shard1.peering.api").filter
    (fun c => !((handles.find? (fun (a, b, _) => a == .shard2 && b == .shard1)).map
      (fun (_, _, hs) => hs.any (·.name == c))).getD false)

#guard unhandled == ["partition"]

end Project.Session
