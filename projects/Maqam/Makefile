# Maqam project: specification checks, the Rust app's build and tests, and the book.
# Requires the LeanFM installation two directories up (`make build` there).
LEANFM := $(abspath ../..)

.PHONY: all check spec-check app-check book clean

all: check book

# Canonical LeanFM project check: compiles spec/Requirements.lean and
# spec/Implementation.lean in the sandbox, validates both and the proto,
# and derives spec/tasks.json.
spec-check:
	cd $(LEANFM) && python3 scripts/chatui_specification.py $(CURDIR) \
	  Project.Requirements.requirements Project.Implementation.implementation

# cargo build and test of the reverse-engineered snapshot (offline: the
# dependency set is pinned by source/Cargo.lock).
app-check:
	$(MAKE) -C source check

book:
	$(MAKE) -C book

check: spec-check app-check

clean:
	$(MAKE) -C book clean
	$(MAKE) -C source clean
