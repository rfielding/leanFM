# Requirement refs: goserver; spec/runtime.json; durable local launch contract.
.PHONY: web build run serve stop test check book-tour clean
GO ?= $(if $(wildcard ../../../.toolchains/go/bin/go),$(abspath ../../../.toolchains/go/bin/go),go)
PORT ?= 8081
export GOCACHE := $(abspath ../.cache/go-build)
export GOMODCACHE := $(abspath ../.cache/go-mod)
BINARY := ../.cache/goserver
# The browser app: React + TypeScript in web/, built into cmd/demo/static/app/ and embedded by Go.
web:
	@test -d web/node_modules || (cd web && npm ci --no-audit --no-fund)
	cd web && npm run check && npm run build && npm run check:bundle
build: web
	@mkdir -p ../.cache
	$(GO) build -o $(BINARY) ./cmd/demo
run: build
	@GOSERVER_PORT=$(PORT) python3 $(abspath runtime.py) run
serve: run
stop:
	python3 $(abspath runtime.py) stop
test:
	$(GO) test -race ./...
check: build test
book-tour: build
	python3 book_tour.py
clean:
	$(RM) $(BINARY)
	$(RM) -r cmd/demo/static/app
