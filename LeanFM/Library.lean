import LeanFM.Env
import LeanFM.EventLog
import LeanFM.LogIndex
import LeanFM.ProjectRoots
import LeanFM.Launch
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
import LeanFM.Session
import LeanFM.Generated.PlaceOrder

/-! Every LeanFM module except the tests. Executables import this, not the LeanFM root: the root
also imports every test module, and an executable linking those would compute their top-level
constants each time it starts (the chat server took 26 s to open its port). -/
