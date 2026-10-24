import LeanFM.ReferenceExamples.RequestImplementation

open LeanFM LeanFM.ReferenceExamples.Request

-- Accepted contracts: chat_layers_mutate_only_their_artifacts,
-- recoverable_failures_are_fixed_before_return. Compile the exact advertised
-- mapping and validate its traceability against the companion requirements.
example : validateImplementationSpec spec implementation = [] := by native_decide
example : leanFMImplementationReference.endsWith
    ((include_str "RequestImplementation.lean") ++ "\n```\n") = true := by native_decide
