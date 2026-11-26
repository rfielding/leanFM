-- This module serves as the root of the `LeanFM` library.
-- Import modules here that should be built as part of the library.
-- the library itself, without its tests, which executables import (LeanFM/Library.lean)
import LeanFM.Library
-- the session-type library and its tests (clauses selfhost.session.*)
-- the philosophy calculator example and its tests
import LeanFM.Philosophy.ExistenceTests
-- the MCP session tools and their tests (clauses selfhost.mcp.session.*)
import LeanFM.SessionToolsTests
import LeanFM.Session.GenerativeTests
import LeanFM.Session.DecisionTests
import LeanFM.Session.ChainTests
import LeanFM.Session.SlaTests
import LeanFM.Session.WhereTests
import LeanFM.Session.TypesTests
import LeanFM.Session.RequirementMapsTests
import LeanFM.Session.EnvelopeTests
import LeanFM.Session.ProtoTests
import LeanFM.Session.OAuthTests
import LeanFM.Session.LeanSyntaxTests
import LeanFM.Session.SpecCheckTests
import LeanFM.Session.ActorTests
import LeanFM.Session.LinkedTests
import LeanFM.Session.DerivedTests
import LeanFM.Session.LogSessionsTests
import LeanFM.Session.IdentityTests
import LeanFM.Session.CtlScaleTests
import LeanFM.CallLimitsTests
import LeanFM.Session.LayoutTests
import LeanFM.Session.FaithfulTests
import LeanFM.Session.InstanceTests
import LeanFM.Session.DeploymentTests
import LeanFM.Session.RealizableTests
import LeanFM.Session.GroupTests
import LeanFM.Session.VersionTests
import LeanFM.Session.ExploreTests
import LeanFM.SecretsTests
import LeanFM.CheckMetricsTests
