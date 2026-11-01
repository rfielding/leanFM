# Requirement refs: goserver; spec/runtime.json; durable local launch contract.
.PHONY: build run serve stop test check book-tour clean
GO ?= $(if $(wildcard ../../../.toolchains/go/bin/go),$(abspath ../../../.toolchains/go/bin/go),go)
PORT ?= 8081
export GOCACHE := $(abspath ../.cache/go-build)
export GOMODCACHE := $(abspath ../.cache/go-mod)
BINARY := ../.cache/goserver
build:
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
