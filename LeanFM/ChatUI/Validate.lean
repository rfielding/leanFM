import LeanFM.ChatUI.Requirements
import LeanFM.ChatUI.Implementation

open LeanFM.ChatUI.Requirements

#eval IO.println validationReport
#eval IO.println "--- chat interaction ---"
#eval IO.println chatInteractionMermaid
#eval IO.println "--- chat state machine ---"
#eval IO.println chatStateMachineMermaid
#eval IO.println "--- signup accepted interaction ---"
#eval IO.println signupAcceptedInteractionMermaid
#eval IO.println "--- signup rejected interaction ---"
#eval IO.println signupRejectedInteractionMermaid
#eval IO.println "--- signup state machine ---"
#eval IO.println signupStateMachineMermaid
#eval IO.println "--- markerboard interaction ---"
#eval IO.println markerboardInteractionMermaid
#eval IO.println "--- artifacts state machine ---"
#eval IO.println artifactsStateMachineMermaid
#eval IO.println "--- task-model interaction ---"
#eval IO.println inspectTaskModelInteractionMermaid
#eval IO.println "--- task-model state machine ---"
#eval IO.println inspectTaskModelStateMachineMermaid
#eval IO.println "--- web research interaction ---"
#eval IO.println webResearchInteractionMermaid
#eval IO.println "--- web research state machine ---"
#eval IO.println webResearchStateMachineMermaid
#eval IO.println "--- markerboard AI assistance interaction ---"
#eval IO.println markerboardAssistInteractionMermaid
#eval IO.println "--- markerboard AI assistance state machine ---"
#eval IO.println markerboardAssistStateMachineMermaid
#eval IO.print LeanFM.ChatUI.Implementation.validationReport
