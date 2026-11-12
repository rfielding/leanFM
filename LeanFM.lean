-- This module serves as the root of the `LeanFM` library.
-- Import modules here that should be built as part of the library.
import LeanFM.Basic
import LeanFM.Assets
import LeanFM.CTL
import LeanFM.MDP
import LeanFM.MDPDiagram
import LeanFM.Protocol
import LeanFM.StreamStats
import LeanFM.Characterization
import LeanFM.UiModel
import LeanFM.Artifacts
import LeanFM.Logic
import LeanFM.Overlay
import LeanFM.ReliabilityDiagram
import LeanFM.LLMGenerated.Requirements
import LeanFM.LLMGenerated.Implementation
import LeanFM.StaticAssets
import LeanFM.Render
import LeanFM.MCP
-- the session-type library and its tests (clauses selfhost.session.*)
import LeanFM.Session
-- the philosophy calculator example and its tests
import LeanFM.Philosophy.ExistenceTests
-- the MCP session tools and their tests (clauses selfhost.mcp.session.*)
import LeanFM.SessionToolsTests

import LeanFM.Session.GenerativeTests

import LeanFM.Session.DecisionTests
import LeanFM.Session.ChainTests
import LeanFM.Session.SlaTests
import LeanFM.SecretsTests
import LeanFM.CheckMetricsTests
