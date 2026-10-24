import LeanFM.ReferenceExamples.Request

open LeanFM LeanFM.ReferenceExamples.Request

-- Refs: property:web_ui_replaces_external_coding_session;
-- property:chat_layers_mutate_only_their_artifacts. The advertised example is
-- checked by the same validators as generated project specifications.
example : validateRequirementSpec spec = [] := by native_decide
example : validateRequirementProtoFile spec protoSource = [] := by native_decide
example : spec.tasks.isEmpty = false := by native_decide
example : spec.grammars.isEmpty = false := by native_decide
example : spec.processes.isEmpty = false := by native_decide
example : spec.requiredProofs.isEmpty = false := by native_decide
example : spec.properties.isEmpty = false := by native_decide
example : spec.desiredOutputs.isEmpty = false := by native_decide

-- Keep the live reference and the module that is actually checked identical.
example : leanFMRequirementsReference.endsWith
    ((include_str "Request.lean") ++ "\n```\n") = true := by native_decide
