# maqam-live: uniform targets for the LeanFM project (the upstream Makefile only
# wrapped scripts/ that are not part of the snapshot). A terminal app, not a
# web server: `run` opens the TUI in the foreground; `serve` is its alias.
CARGO := cargo
FLAGS := --release --offline

.PHONY: build run serve stop test check clean

build:
	$(CARGO) build $(FLAGS)

run: build
	$(CARGO) run $(FLAGS)

serve: run

# The TUI owns its terminal; quitting it (q) is how it stops.
stop:
	@echo "maqam-live runs in the foreground; quit it with q"

test:
	$(CARGO) test $(FLAGS)

check: build test

clean:
	$(CARGO) clean
