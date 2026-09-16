SHELL := /usr/bin/env bash

HOST ?= 127.0.0.1
PORT ?= 8080
BASE_URL := http://$(HOST):$(PORT)
PASSWORD ?= leanfm
COOKIES ?= /tmp/leanfm.cookies
ROOT_HTML ?= /tmp/leanfm-root.html
EXAMPLES_HTML ?= /tmp/leanfm-examples.html

.PHONY: build run serve stop check http-check validate proto diagrams scripts clean

build:
	lake build leanfm-server

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

check: build validate diagrams

validate:
	@lake exe leanfm | rg 'Per-task FSM CTL checks|CTL from initial observation|AF terminal|AG capacity'
	@lake exe leanfm-validate | rg '^ok: all generated requirements'
	@lake env lean LeanFM/LLMGenerated/Requirements.lean

http-check:
	@curl -fsS "$(BASE_URL)/health"
	@curl -fsS -c "$(COOKIES)" -b "$(COOKIES)" -L -d 'password=$(PASSWORD)' -o "$(ROOT_HTML)" "$(BASE_URL)/login"
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/tools/llm-generated/requirements/prompt" | rg 'LeanFM/LLMGenerated/Requirements\.lean|Requirements\.proto|MessageFraming'
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/tools/llm-generated/requirements/validate" | rg '^ok: all generated requirements'
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/tools/aggregate-graph/validate" | rg '^ok: all generated requirements'
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/llm-generated/requirements.proto" | rg 'message RequirementEnvelope|oneof atom|message Docs_GetRequest'
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/openapi.yaml" | rg 'openapi: 3\.1\.0|x-leanfm-requirement|Docs\.GetRequest'
	@curl -fsS -b "$(COOKIES)" -o "$(EXAMPLES_HTML)" "$(BASE_URL)/examples"
	@ROOT_HTML="$(ROOT_HTML)" EXAMPLES_HTML="$(EXAMPLES_HTML)" node -e 'const fs=require("fs"),vm=require("vm"); for (const f of [process.env.ROOT_HTML,process.env.EXAMPLES_HTML]) { const html=fs.readFileSync(f,"utf8"); const re=/<script([^>]*)>([\s\S]*?)<\/script>/gi; let m,n=0; while ((m=re.exec(html))) { if (/type=["'\'']application\/json["'\'']/i.test(m[1])) continue; const code=m[2].trim(); if (code) new vm.Script(code,{filename:f+":inline"+(++n)}); } console.log(f+": ok ("+n+" inline scripts)"); }'

proto:
	@curl -fsS -b "$(COOKIES)" "$(BASE_URL)/llm-generated/requirements.proto"

diagrams:
	lake exe leanfm-diagrams

scripts:
	node scripts/format_assets.js
	node scripts/embed_static_assets.js

clean:
	lake clean
