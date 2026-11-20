# maqam-live in Zig. Needs zig 0.17 and libasound2-dev; nothing outside this directory.
# The targets the project's scripts/compare.py measures every implementation by:
#   check   build and run every test
#   render  SESSION=... CYCLES=... RATE=... WAV=...   offline render (deterministic)
#   bench   SESSION=... SECONDS=... [NAM=...]           live audio path against a null device
ZIG ?= zig
BIN := zig-out/bin/maqam-live
SESSION ?= default.mq
CYCLES ?= 1
RATE ?= 48000
WAV ?= render.wav
SECONDS ?= 10
NAM ?=

.PHONY: all build check test render bench run clean
all: build

build:
	$(ZIG) build --release

test:
	$(ZIG) build test --summary all

check: build test

render: build
	$(BIN) --render $(SESSION) --cycles $(CYCLES) --rate $(RATE) --wav $(WAV)

bench: build
	$(BIN) --bench $(SESSION) --seconds $(SECONDS) --frames 64 --rate 48000 $(if $(NAM),--nam $(NAM),) $(if $(PERIOD_LOG),--period-log $(PERIOD_LOG),)

run: build
	$(BIN)

clean:
	rm -rf zig-out .zig-cache
