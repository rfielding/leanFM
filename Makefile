SHELL := /usr/bin/env bash

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

.PHONY: build ui-build run serve stop check chatui-check go-toolchain paxos-check paxos-run http-check validate proto diagrams mdp-example-check scripts bakery-data bakery-stats book book-clean video-check video video-narrated clean

build: ui-build
	lake build leanfm-server

ui-build:
	@test -d ui/node_modules || (cd ui && npm ci)
	cd ui && npm run check && npm run build && npm run check:bundle
	@lake clean

run:
	lake exe leanfm

serve:
	lake exe leanfm-server

stop:
	@pid="$$(ss -ltnp 2>/dev/null | rg ':$(PORT)' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n 1)"; \
	if [[ -n "$$pid" ]]; then \
	  kill "$$pid"; \
	  echo "stopped leanfm-server pid=$$pid"; \
	else \
	  echo "no leanfm-server listening on :$(PORT)"; \
	fi

check: build validate diagrams mdp-example-check paxos-check video-check selfhost-check

mdp-example-check:
	lake env lean --run StochasticUserMDPExample.lean

.PHONY: selfhost-check
selfhost-check:
	lake build LeanFM.LLMGenerated.Requirements
	lake env lean LeanFM/LLMGenerated/SelfHostingTests.lean
	lake env lean --run ReviewSelfHosting.lean

video-check:
	python3 scripts/validate_video_overview.py

video: video-check
	$(VIDEO_PYTHON) -m manim -qm --media_dir video/media --output_file leanfm-overview.mp4 video/manim_overview.py LeanFMOverview
	cp video/media/videos/manim_overview/720p30/leanfm-overview.mp4 video/leanfm-overview.mp4

video-narrated: video-check
	$(VIDEO_PYTHON) scripts/prepare_video_narration.py
	$(MAKE) video
	$(VIDEO_PYTHON) scripts/render_video_narration.py

.PHONY: kerberos-video
kerberos-video:
	$(VIDEO_PYTHON) scripts/prepare_video_narration.py --project video/kerberos
	$(VIDEO_PYTHON) -m manim -qm --media_dir video/kerberos/media --output_file kerberos.mp4 video/kerberos/scenes.py KerberosVideo
	ffmpeg -hide_banner -loglevel error -y -i video/kerberos/media/videos/scenes/720p30/kerberos.mp4 -i video/kerberos/narration.wav -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -b:a 160k -shortest video/kerberos/kerberos-narrated.mp4

chatui-check: build
	python3 scripts/chatui_crypto_test.py
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

paxos-check:
	@lake env lean ValidatePaxosKV.lean | rg '^ok: Paxos KV requirements|^ok: generated implementation plan'
	@go test ./...

.PHONY: goserver-check
goserver-check: go-toolchain
	$(MAKE) -C projects/go-server check

.PHONY: chatui-browser-check
chatui-browser-check: build
	LEANFM_TEST_BROWSER=1 bash scripts/chatui_http_check.sh

paxos-run:
	@echo 'Run three replicas, then: go run ./cmd/paxos-kv web'

validate:
	@lake exe leanfm | rg 'Per-task FSM CTL checks|CTL from initial observation|AF terminal|AG capacity'
	@lake exe leanfm-validate | rg '^ok: all generated requirements'
	@lake exe leanfm-validate | rg '^ok: generated implementation plan'
	@lake env lean LeanFM/LLMGenerated/Requirements.lean
	@lake env lean LeanFM/LLMGenerated/Implementation.lean
	@lake env lean LeanFM/ArtifactsTests.lean
	@lake env lean LeanFM/ProtocolTests.lean
	@lake env lean LeanFM/StreamStatsTests.lean
	@lake env lean LeanFM/PopulationTests.lean
	@lake env lean LeanFM/CharacterizationTests.lean
	@lake env lean LeanFM/CTLTests.lean
	@lake env lean --run LeanFM/MCPTests.lean
	@python3 scripts/roundtrip_generated_scenario.py
	@python3 scripts/reduce_bakery_events.py --output /tmp/leanfm-bakery-stats.json --tex-output /tmp/leanfm-bakery-stats.tex >/dev/null
	@cmp examples/bakery-stats.json /tmp/leanfm-bakery-stats.json
	@cmp book/generated/bakery-stats.tex /tmp/leanfm-bakery-stats.tex

bakery-data:
	python3 scripts/generate_bakery_events.py

bakery-stats:
	python3 scripts/reduce_bakery_events.py --tex-output book/generated/bakery-stats.tex

http-check:
	@curl -fsS "$(BASE_URL)/health"
	@curl -fsS -X POST "$(BASE_URL)/mcp" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"make-http-check","version":"1"}}}' | rg '"protocolVersion":"2025-06-18"|durable agent context'
	@curl -fsS "$(BASE_URL)/tools/leanfm-language/requirements-reference" | rg '^# LeanFM requirement language reference'
	@curl -fsS "$(BASE_URL)/tools/leanfm-language/implementation-reference" | rg '^# LeanFM implementation language reference'
	@curl -fsS "$(BASE_URL)/tools/requirements/interrogation" | rg '^LeanFM requirements interrogation checklist'
	@curl -fsS -c "$(COOKIES)" -b "$(COOKIES)" -L -d 'password=$(PASSWORD)' -o "$(ROOT_HTML)" "$(BASE_URL)/login"
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/tools/llm-generated/requirements/prompt" | rg 'LeanFM/LLMGenerated/Requirements\.lean|Requirements\.proto|MessageFraming'
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/tools/llm-generated/requirements/validate" | rg '^ok: all generated requirements'
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/tools/aggregate-graph/validate" | rg '^ok: all generated requirements'
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/api/session" | rg 'requirementsLean|requirementsProto'
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/api/session/generated/requirements.lean" | rg 'namespace LeanFM\.LLMGenerated\.Requirements'
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/api/session/generated/requirements.proto" | rg 'message RequirementEnvelope|oneof atom|message Docs_GetRequest'
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/llm-generated/requirements.proto" | rg 'message RequirementEnvelope|oneof atom|message Docs_GetRequest'
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/openapi.yaml" | rg 'openapi: 3\.1\.0|x-leanfm-requirement|Docs\.GetRequest'
	@curl -fsS -b "$(COOKIES)" -o "$(EXAMPLES_HTML)" "$(BASE_URL)/examples"
	@ROOT_HTML="$(ROOT_HTML)" EXAMPLES_HTML="$(EXAMPLES_HTML)" node -e 'const fs=require("fs"),vm=require("vm"); for (const f of [process.env.ROOT_HTML,process.env.EXAMPLES_HTML]) { const html=fs.readFileSync(f,"utf8"); const re=/<script([^>]*)>([\s\S]*?)<\/script>/gi; let m,n=0; while ((m=re.exec(html))) { if (/type=["'\'']application\/json["'\'']/i.test(m[1])) continue; const code=m[2].trim(); if (code) new vm.Script(code,{filename:f+":inline"+(++n)}); } console.log(f+": ok ("+n+" inline scripts)"); }'

proto:
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/llm-generated/requirements.proto"

diagrams:
	lake exe leanfm-diagrams
	lake env lean --run RuntimeReliabilityDiagram.lean
	lake env lean --run NestedForkJoinExample.lean
	lake env lean --run StochasticUserMDPExample.lean
	lake env lean --run BakeryFlowExample.lean
	lake env lean --run OAuthGrammarExample.lean
	lake env lean --run MCPInteractionExample.lean
	lake env lean --run WebServerProtocolChapter.lean
	@dot -Tpng diagrams/paxos-kv.dot -o diagrams/paxos-kv.png
	@dot -Tpng diagrams/paxos-quorum-write.dot -o diagrams/paxos-quorum-write.png
	@dot -Tpng diagrams/paxos-linearizable-list.dot -o diagrams/paxos-linearizable-list.png
	@dot -Tpng diagrams/paxos-recovery.dot -o diagrams/paxos-recovery.png
	@dot -Tpng diagrams/paxos-quorum-write-messages.dot -o diagrams/paxos-quorum-write-messages.png

scripts:
	node scripts/format_assets.js
	node scripts/embed_static_assets.js

book:
	lake env lean --run RuntimeReliabilityDiagram.lean
	lake env lean --run NestedForkJoinExample.lean
	lake env lean --run StochasticUserMDPExample.lean
	lake env lean --run BakeryFlowExample.lean
	lake env lean --run OAuthGrammarExample.lean
	lake env lean --run MCPInteractionExample.lean
	lake env lean --run WebServerProtocolChapter.lean
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
