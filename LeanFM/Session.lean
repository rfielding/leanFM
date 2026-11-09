import LeanFM.Session.Global
import LeanFM.Session.Physics
import LeanFM.Session.Topology
import LeanFM.Session.Http
import LeanFM.Session.Spec
import LeanFM.Session.Syntax
import LeanFM.Session.Knowledge
import LeanFM.Session.Diagram
import LeanFM.Session.Calls
import LeanFM.Session.Events
import LeanFM.Session.Text
import LeanFM.Session.Conform
import LeanFM.Session.Skeleton
import LeanFM.Session.SkeletonTs
import LeanFM.Session.ProjectionTests
import LeanFM.Session.SessionTests

/-!
# Session types for LeanFM

Pull in only what you use:

* `LeanFM.Session.Global`   global types, projection, the choice and cause rules (always)
* `LeanFM.Session.Syntax`   the `protocol` notation
* `LeanFM.Session.Physics`  channel declarations and presets
* `LeanFM.Session.Topology` interfaces, scopes and the deployment tree
* `LeanFM.Session.Http`     the HTTP call discipline (cut and un-cut)
* `LeanFM.Session.Diagram`  sequence diagrams drawn from a global type
* `LeanFM.Session.Calls`    calls (request, detail, responses) and typestate APIs
* `LeanFM.Session.Events`   event streams generated from a global type
* `LeanFM.Session.Text`     protocol text read without elaborating it (for MCP clients)
* `LeanFM.Session.Conform`  checking a logged run against the protocol
* `LeanFM.Session.Skeleton` each role's typestate as code to implement
* `LeanFM.Session.Spec`     properties, assumptions and handled conditions

This module brings in all of them.
-/
