import LeanFM.Session.Global
import LeanFM.Session.Physics
import LeanFM.Session.Topology
import LeanFM.Session.Http
import LeanFM.Session.Spec
import LeanFM.Session.Syntax
import LeanFM.Session.Knowledge

/-!
# Session types for LeanFM

Pull in only what you use:

* `LeanFM.Session.Global`   global types, projection, the choice and cause rules (always)
* `LeanFM.Session.Syntax`   the `protocol` notation
* `LeanFM.Session.Physics`  channel declarations and presets
* `LeanFM.Session.Topology` interfaces, scopes and the deployment tree
* `LeanFM.Session.Http`     the HTTP call discipline (cut and un-cut)
* `LeanFM.Session.Spec`     properties, assumptions and handled conditions

This module brings in all of them.
-/
