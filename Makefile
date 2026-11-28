SHELL := /usr/bin/env bash

# One make at a time in this checkout (clause selfhost.build.lock): every run takes an exclusive lock
# on .cache/make.lock (LEANFM_MAKE_LOCK names another path) and waits for a run already holding it.
# Make's own recursive calls run with LEANFM_MAKE_LOCKED=1 and do not wait on their caller's lock.
# serve, run, stop and claude start or stop long-lived processes and do not hold it (serve takes it
# only while building the server binary).
LEANFM_MAKE_LOCK ?= .cache/make.lock
UNLOCKED_GOALS := serve run stop claude
LOCK_GOALS := $(if $(LEANFM_MAKE_LOCKED),,$(if $(MAKECMDGOALS),$(filter-out $(UNLOCKED_GOALS),$(MAKECMDGOALS)),default))
ifneq ($(LOCK_GOALS),)
.NOTPARALLEL:
.PHONY: leanfm-make-lock leanfm-default $(MAKECMDGOALS)
$(if $(MAKECMDGOALS),$(MAKECMDGOALS),leanfm-default): leanfm-make-lock ; @:
leanfm-make-lock:
	@mkdir -p $(dir $(LEANFM_MAKE_LOCK))
	@flock -n $(LEANFM_MAKE_LOCK) true || echo "make: another make is running in this checkout; waiting for it ($(LEANFM_MAKE_LOCK))"
	@LEANFM_MAKE_LOCKED=1 flock $(LEANFM_MAKE_LOCK) $(MAKE) --no-print-directory $(MAKECMDGOALS)
else

GO_VERSION ?= 1.23.12
GO_SHA256 ?= d3847fef834e9db11bf64e3fb34db9c04db14e068eeb064f49af747010454f90
GO_ARCHIVE := /tmp/leanfm-go$(GO_VERSION).linux-amd64.tar.gz
LOCAL_GO := $(CURDIR)/.toolchains/go/bin/go
export PATH := $(CURDIR)/.toolchains/go/bin:$(PATH)
export GOCACHE := $(CURDIR)/.cache/go-build
export GOMODCACHE := $(CURDIR)/.cache/go-mod

HOST ?= 127.0.0.1
PORT ?= 8080
VIDEO_PYTHON ?= video/.conda/bin/python
BASE_URL := http://$(HOST):$(PORT)
PASSWORD ?= leanfm
COOKIES ?= /tmp/leanfm.cookies
ROOT_HTML ?= /tmp/leanfm-root.html
EXAMPLES_HTML ?= /tmp/leanfm-examples.html

.DEFAULT_GOAL := all

.PHONY: all lean build ui-build run serve claude stop check test chatui-check go-toolchain paxos-check http-check validate proto diagrams mdp-example-check scripts bakery-data bakery-stats book book-clean video-check video video-narrated clean

# `make` rebuilds everything: the browser bundle, every Lean target, and the book.
all: build lean book

build: ui-build
	@python3 scripts/invalidate_include_str.py
	lake build leanfm-server leanfm-mcp

# Every Lean library module and executable, not just the server's imports.
lean: build
	lake build LeanFM leanfm leanfm-server leanfm-diagrams leanfm-validate

ui-build:
	@test -d ui/node_modules || (cd ui && npm ci)
	cd ui && npm run check && npm run build && npm run check:bundle

run:
	lake exe leanfm

serve:
	@mkdir -p $(dir $(LEANFM_MAKE_LOCK))
	$(if $(LEANFM_MAKE_LOCKED),,flock $(LEANFM_MAKE_LOCK)) lake build leanfm-server
	LEANFM_LAUNCHED_NS=$$(date +%s%N) .lake/build/bin/leanfm-server $(foreach p,$(PROJECTS),--project $(p))

claude:
	bash scripts/claude.sh

stop:
	@pid="$$(ss -ltnp 2>/dev/null | rg ':$(PORT)' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n 1)"; \
	if [[ -n "$$pid" ]]; then \
	  kill "$$pid"; \
	  echo "stopped leanfm-server pid=$$pid"; \
	else \
	  echo "no leanfm-server listening on :$(PORT)"; \
	fi

check: make-lock-check env-registry-check sandbox-check build validate diagrams mdp-example-check paxos-check video-check selfhost-check chatui-check constructors-check book-listings-check keepalive-check proxy-check forward-check ctl-tiny-check log-range-check external-project-check run-log-check

mdp-example-check:
	lake env lean --run StochasticUserMDPExample.lean

.PHONY: selfhost-check requirements-check
# every requirement and implementation entry converted to CTL and decided; STRICT=1 fails on sorry too
requirements-check:
	lake env lean --run LeanFM/RequirementsCheck.lean $(if $(STRICT),--strict,)
	lake env lean --run LeanFM/RequirementsCheck.lean --files examples/orders/Requirements.leanfm examples/orders/Implementation.leanfm

selfhost-check:
	lake build LeanFM.LLMGenerated.Requirements
	lake env lean LeanFM/LLMGenerated/SelfHostingTests.lean
	lake env lean --run LeanFM/RequirementsCheck.lean
	lake env lean --run ReviewSelfHosting.lean
	lake env lean --run ReviewResumableWork.lean
	python3 scripts/chatui_work_state_test.py
	python3 scripts/chatui_workspace_test.py

video-check:
	python3 scripts/validate_video_overview.py
	lake env lean video/lean-tutorial/Tour.lean
	lake env lean video/lean-tutorial/protocols/Constructs.leanfm
	lake env lean video/lean-tutorial/protocols/Lookup.leanfm

video: video-check
	$(VIDEO_PYTHON) -m manim -qm --media_dir video/media --output_file leanfm-overview.mp4 video/manim_overview.py LeanFMOverview
	cp video/media/videos/manim_overview/720p30/leanfm-overview.mp4 video/leanfm-overview.mp4

video-narrated: video-check
	$(VIDEO_PYTHON) scripts/prepare_video_narration.py
	$(MAKE) video
	$(VIDEO_PYTHON) scripts/render_video_narration.py

# The book tour (video/book-tour): real terminal steps, real LeanFM answers, local narration.
.PHONY: video-tour
video-tour:
	cp -n examples/guinea-pigs/cage.log logs/devices.log || true
	python3 video/book-tour/capture.py
	python3 video/book-tour/fetch.py
	python3 video/book-tour/live.py 4 40
	python3 video/book-tour/produce.py

.PHONY: kerberos-video
kerberos-video:
	$(VIDEO_PYTHON) scripts/prepare_video_narration.py --project video/kerberos
	$(VIDEO_PYTHON) -m manim -qm --media_dir video/kerberos/media --output_file kerberos.mp4 video/kerberos/scenes.py KerberosVideo
	ffmpeg -hide_banner -loglevel error -y -i video/kerberos/media/videos/scenes/720p30/kerberos.mp4 -i video/kerberos/narration.wav -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -b:a 160k -shortest video/kerberos/kerberos-narrated.mp4

chatui-check: sandbox-check build
	python3 scripts/chatui_crypto_test.py
	python3 scripts/chatui_patch_test.py
	python3 scripts/chatui_media_test.py
	python3 scripts/chatui_specification_test.py
	python3 scripts/chatui_project_state_test.py
	python3 scripts/chatui_work_state_test.py
	python3 scripts/chatui_workspace_reset_test.py
	python3 scripts/chatui_workspace_test.py
	python3 scripts/chatui_command_test.py
	python3 scripts/chatui_runtime_test.py
	python3 scripts/chatui_application_unit_test.py
	python3 scripts/check_ui_tour.py
	lake env lean --run LeanFM/LLMGenerated/ApplicationLaunchTests.lean
	lake env lean LeanFM/ChatUI/ProviderTests.lean
	lake env lean LeanFM/ChatUI/HttpRequestTests.lean
	bash scripts/chatui_http_check.sh
	lake build LeanFM.ChatUI.Implementation
	@lake env lean LeanFM/ChatUI/Validate.lean | rg '^ok: ChatUI implementation decisions are traceable$$'

go-toolchain:
	@set -e; if [[ -x "$(LOCAL_GO)" ]]; then \
	  "$(LOCAL_GO)" version; \
	else \
	  mkdir -p .toolchains; \
	  curl -fsSL "https://go.dev/dl/go$(GO_VERSION).linux-amd64.tar.gz" -o "$(GO_ARCHIVE)"; \
	  echo "$(GO_SHA256)  $(GO_ARCHIVE)" | sha256sum -c -; \
	  tar -C .toolchains -xzf "$(GO_ARCHIVE)"; \
	  rm -f "$(GO_ARCHIVE)"; \
	  "$(LOCAL_GO)" version; \
	fi

# The reference example project: spec check plus go vet/test.
paxos-check: build
	$(MAKE) -C projects/PaxosKV check

.PHONY: chatui-browser-check
chatui-browser-check: build
	LEANFM_TEST_BROWSER=1 bash scripts/chatui_http_check.sh

validate:
	@lake exe leanfm | rg 'Per-task FSM CTL checks|CTL from initial observation|AF terminal|AG capacity'
	@lake exe leanfm-validate | rg '^ok: all generated requirements'
	@lake exe leanfm-validate | rg '^ok: generated implementation plan'
	@lake env lean LeanFM/LLMGenerated/Requirements.lean
	@lake env lean LeanFM/LLMGenerated/Implementation.lean
	@lake env lean LeanFM/ArtifactsTests.lean
	@lake build LeanFM.ReferenceExamples.Request
	@lake env lean LeanFM/ReferenceExamples/RequestTests.lean
	@lake build LeanFM.ReferenceExamples.RequestImplementation
	@lake env lean LeanFM/ReferenceExamples/RequestImplementationTests.lean
	@lake env lean LeanFM/ProtocolTests.lean
	@lake env lean LeanFM/StreamStatsTests.lean
	@lake env lean LeanFM/PopulationTests.lean
	@lake env lean LeanFM/CharacterizationTests.lean
	@lake env lean LeanFM/CTLTests.lean
	@lake build LeanFM.MCPHost
	@lake build leanfm-mcp-tests leanfm-logic-tests
	@.lake/build/bin/leanfm-mcp-tests
	@.lake/build/bin/leanfm-logic-tests
	@python3 scripts/roundtrip_generated_scenario.py
	@python3 scripts/reduce_bakery_events.py --output /tmp/leanfm-bakery-stats.json --tex-output /tmp/leanfm-bakery-stats.tex >/dev/null
	@cmp examples/bakery-stats.json /tmp/leanfm-bakery-stats.json
	@cmp book/generated/bakery-stats.tex /tmp/leanfm-bakery-stats.tex

bakery-data:
	python3 scripts/generate_bakery_events.py

bakery-stats:
	python3 scripts/reduce_bakery_events.py --tex-output book/generated/bakery-stats.tex

http-check:
	python3 scripts/http_smoke.py "$(BASE_URL)"
	bash scripts/chatui_http_check.sh

proto:
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/llm-generated/requirements.proto"

diagrams:
	lake exe leanfm-diagrams
	lake env lean --run RuntimeReliabilityDiagram.lean
	lake env lean --run NestedForkJoinExample.lean
	lake env lean --run StochasticUserMDPExample.lean
	lake env lean --run BakeryFlowExample.lean
	lake env lean --run OAuthGrammarExample.lean
	lake env lean --run TopologyExample.lean
	lake env lean --run MCPInteractionExample.lean
	lake env lean --run LogicInteractionExample.lean
	lake env lean --run WebServerProtocolChapter.lean

scripts:
	node scripts/format_assets.js
	node scripts/embed_static_assets.js

book: lean
	lake env lean --run RuntimeReliabilityDiagram.lean
	lake env lean --run NestedForkJoinExample.lean
	lake env lean --run StochasticUserMDPExample.lean
	lake env lean --run BakeryFlowExample.lean
	lake env lean --run OAuthGrammarExample.lean
	lake env lean --run TopologyExample.lean
	lake env lean --run MCPInteractionExample.lean
	lake env lean --run LogicInteractionExample.lean
	lake env lean --run WebServerProtocolChapter.lean
	lake env lean --run NeedhamSchroeder.lean
	lake env lean --run SpansChapterExample.lean
	lake env lean --run InstancesChapterExample.lean
	lake env lean --run LanguageChapterExample.lean
	python3 scripts/svg_to_pdf.py book/generated/lang-*.svg
	lake env lean --run SlaChapterExample.lean
	lake env lean --run SecretsChapterExample.lean
	lake env lean --run OAuthChapterExample.lean
	python3 scripts/svg_to_pdf.py book/generated/oauth-signin-*.svg
	lake env lean --run SessionFiles.lean examples/oauth
	lake env lean --run VersionsChapterExample.lean
	lake env lean --run CtlBookExample.lean
	python3 scripts/svg_to_pdf.py book/generated/ctl-*.svg
	for f in book/generated/ctl-*-ts-*.dot; do dot -Tpdf "$$f" -o "$${f%.dot}.pdf"; done
	lake env lean --run RequirementListsExample.lean
	python3 scripts/svg_to_pdf.py book/generated/req-*.svg
	lake env lean --run SignalChapterExample.lean
	python3 scripts/svg_to_pdf.py book/generated/sig-*.svg
	lake env lean --run BookListingsCheck.lean
	$(MAKE) -C book

.PHONY: tla-toolchain tla-check
tla-toolchain:
	mkdir -p .toolchains/tla
	curl -fsSL https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar -o .toolchains/tla/tla2tools-1.7.4.jar
	echo '936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88  .toolchains/tla/tla2tools-1.7.4.jar' | sha256sum -c -

tla-check:
	python3 scripts/check_tla_example.py

book-clean:
	$(MAKE) -C book clean

clean:
	lake clean

# Persistent lifecycle, browser isolation and observed protobuf trace checks.
.PHONY: application-check ui-snapshots
application-check: build
	python3 scripts/chatui_application_test.py
ui-snapshots:
	bash scripts/chatui_ui_snapshots.sh

# These suites share build products; do not clean them under concurrent checks.
.NOTPARALLEL: check chatui-check
.PHONY: sandbox-check
sandbox-check:
	python3 scripts/chatui_sandbox_check.py

# CTL in a page of Lean, printed in the book's Chapter 4: it compiles, and its guards hold.
.PHONY: ctl-tiny-check
ctl-tiny-check:
	lake env lean book/examples/CtlTiny.lean

# The stdio relay to a running HTTP server, for Claude Desktop and Codex (selfhost.mcp.forward).
.PHONY: forward-check
forward-check: build
	python3 -I scripts/forward_check.py

# The one-page Go reverse proxy for a public host (selfhost.mcp.proxy).
.PHONY: proxy-check
proxy-check: go-toolchain
	cd deploy/mcp/proxy && "$(LOCAL_GO)" vet ./... && "$(LOCAL_GO)" test ./...

# HTTP keep-alive on both servers, over raw sockets (selfhost.mcp.keepalive).
.PHONY: keepalive-check
keepalive-check: build
	python3 -I scripts/keepalive_check.py

# Every listing of LeanFM text in the book passes the checker as printed (selfhost.book.listings).
.PHONY: book-listings-check
book-listings-check: build
	lake env lean --run BookListingsCheck.lean --self-test
	lake env lean --run BookListingsCheck.lean

.PHONY: constructors-check
constructors-check:
	lake env lean ./ConstructorsExample.lean

# The short tier: test what changed (clause selfhost.build.changed-tests); make check is the long tier.
.PHONY: test
test:
	python3 -I scripts/changed_tests.py --self-test
	python3 -I scripts/changed_tests.py

# Every environment variable read is in LeanFM/Env.lean (clause selfhost.env.registry).
# Logs read by line ranges: 206, 416, ETag, appends (clause selfhost.session.log-paging).
.PHONY: log-range-check
log-range-check:
	lake build leanfm-server
	python3 -I scripts/log_range_check.py

# Projects outside the checkout, named by --project (clause selfhost.project.external).
.PHONY: external-project-check
run-log-check:
	lake build leanfm-mcp
	python3 -I scripts/mcp_run_log.py

external-project-check:
	lake build leanfm-server leanfm-mcp
	python3 -I scripts/external_project_check.py

# The LeanFM-Limits header raises limits for one HTTP request (clause selfhost.mcp.limits).
.PHONY: header-limits-check
header-limits-check:
	lake build leanfm-server leanfm-mcp
	python3 -I scripts/header_limits_check.py

.PHONY: env-registry-check
env-registry-check:
	python3 -I scripts/env_registry_check.py

# Serialized make runs (clause selfhost.build.lock): two makes at once must not overlap.
.PHONY: make-lock-check lock-probe
make-lock-check:
	python3 -I scripts/make_lock_check.py
LOCK_PROBE_LOG ?= .cache/lock-probe.log
lock-probe:
	@echo "start $$(date +%s%N)" >> $(LOCK_PROBE_LOG); sleep 2; echo "end $$(date +%s%N)" >> $(LOCK_PROBE_LOG)

endif
