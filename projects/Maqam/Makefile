# Maqam project: specification checks, each implementation's build and tests, and the book.
# The implementations are listed in manifest.json (impl/<name>/); rust is the default.
# Requires the LeanFM installation two directories up (`make build` there).
LEANFM := $(abspath ../..)

.PHONY: all check spec-check app-check zig-check book compare clean

all: check book

# Canonical LeanFM project check: compiles spec/Requirements.lean and every
# impl/<name>/Implementation.lean in the sandbox, validates each against the
# same requirements and the proto, and derives spec/tasks.json. Only the
# default implementation (rust) can fail it; the others are reported.
spec-check:
	cd $(LEANFM) && python3 scripts/chatui_specification.py $(CURDIR) \
	  Project.Requirements.requirements Project.Implementation.implementation

# cargo build and test of the reverse-engineered snapshot (offline: the
# dependency set is pinned by impl/rust/source/Cargo.lock).
app-check:
	$(MAKE) -C impl/rust/source check

# zig build and test of the Zig port; needs only zig 0.17 and libasound2-dev, never the Rust tree.
zig-check:
	$(MAKE) -C impl/zig/source check

book:
	$(MAKE) -C book

# Measure every implementation against the same specification (spec status, check,
# deterministic offline render, null test against the default, event-log conformance
# with LeanFM's session_conform, real-time bench) into reports/compare/. Needs make
# spec-check first and, for conformance, make serve in the LeanFM root.
# COMPARE_ARGS passes options, e.g. COMPARE_ARGS="--nam capture.nam --only rust,zig".
compare:
	python3 scripts/compare.py $(COMPARE_ARGS)

check: spec-check app-check zig-check

clean:
	$(MAKE) -C book clean
	$(MAKE) -C impl/rust/source clean
	$(MAKE) -C impl/zig/source clean
