SHELL := /usr/bin/env bash
LEANFM_ROOT ?= $(abspath ../..)
GO ?= $(if $(wildcard $(LEANFM_ROOT)/.toolchains/go/bin/go),$(LEANFM_ROOT)/.toolchains/go/bin/go,go)
export GOCACHE := $(CURDIR)/.cache/go-build
export GOMODCACHE := $(CURDIR)/.cache/go-mod
export TMPDIR := $(CURDIR)/.cache/tmp

.PHONY: build run check spec-check browser-check book checkpoint
build: spec-check
	@mkdir -p .cache/tmp
	cd source && $(GO) build -o ../.cache/goserver ./cmd/goserver
	cd source && $(GO) build -o ../.cache/replay ./cmd/replay
run: build
	.cache/goserver
spec-check:
	@mkdir -p .cache/proto
	cd $(LEANFM_ROOT) && lake build LeanFM.ChatUI.Server
	@libpath="$$(cd $(LEANFM_ROOT) && lake env printenv LEAN_PATH)"; \
	  export LEAN_PATH="$(CURDIR):$$libpath"; \
	  lean -o spec/Requirements.olean spec/Requirements.lean && \
	  lean spec/Implementation.lean && lean --run spec/Requirements.lean
	protoc --proto_path=spec --python_out=.cache/proto spec/Requirements.proto
	python3 tests/render_contract.py
check: build
	cd source && $(GO) test -race -count=1 ./...
	node tests/rules_check.mjs
	python3 tests/startup_check.py
	python3 tests/protocol_check.py
browser-check: build
	python3 tests/browser_check.py
book:
	$(MAKE) -C book
checkpoint:
	$(MAKE) check
	$(MAKE) browser-check
	$(MAKE) check
	$(MAKE) book
	python3 tests/evidence_manifest.py
