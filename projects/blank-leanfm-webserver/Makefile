.PHONY: bootstrap reference interrogation validate render check

bootstrap:
	@lake build LeanFM

reference: bootstrap
	@lake env lean --run bootstrap/RequirementsReference.lean

interrogation: bootstrap
	@lake env lean --run bootstrap/Interrogation.lean

validate: bootstrap
	@lake build Specification
	@lake env lean --run bootstrap/ValidateRequirements.lean
	@protoc --proto_path=Specification --descriptor_set_out=.lake/Requirements.pb Specification/Requirements.proto

render: bootstrap
	@lake build Specification
	@lake env lean --run bootstrap/RenderRequirements.lean

check: validate render
