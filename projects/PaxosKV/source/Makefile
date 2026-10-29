# Requirement refs: paxos_kv.visible_behavior; spec/runtime.json; actor:Runtime.
.PHONY: build run serve stop test check clean clean-data
GO ?= $(if $(wildcard ../../../.toolchains/go/bin/go),$(abspath ../../../.toolchains/go/bin/go),go)
PORT ?= 8082
export GOCACHE := $(abspath ../.cache/go-build)
export GOMODCACHE := $(abspath ../.cache/go-mod)
BINARY := ../.cache/paxos-kv

build:
	@mkdir -p ../.cache
	$(GO) build -o $(BINARY) ./cmd/paxos-kv

# Foreground: three replicas (kv-0..kv-2) and the web app on 127.0.0.1:$(PORT).
run: build
	@PAXOS_WEB_PORT=$(PORT) python3 $(abspath runtime.py) run
serve: run

stop:
	python3 $(abspath runtime.py) stop

test:
	$(GO) vet ./...
	$(GO) test -race ./...

check: build test

clean:
	$(RM) $(BINARY)

# Durable replica state survives restarts; this deletes it.
clean-data:
	$(RM) -r ../.cache/data ../events
