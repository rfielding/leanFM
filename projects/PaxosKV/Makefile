# PaxosKV project: specification checks, derived views, book and app.
# Requires the LeanFM installation two directories up (`make build` there).
LEANFM := $(abspath ../..)
LEAN_OUT := .cache/lean
# Run Lean with the LeanFM library plus this project's compiled spec modules.
LEAN := lake -d $(LEANFM) env sh -c 'LEAN_PATH="$$LEAN_PATH:$(CURDIR)/$(LEAN_OUT)" exec lean "$$@"' lean

.PHONY: all check spec-check views book app-check run stop browser-check clean

all: check views book

# Canonical LeanFM project check: compiles spec/Requirements.lean and
# spec/Implementation.lean in the sandbox, validates both and the proto,
# and derives spec/tasks.json.
spec-check:
	cd $(LEANFM) && python3 scripts/chatui_specification.py $(CURDIR) \
	  Project.Requirements.requirements Project.Implementation.implementation

# Diagrams and SVGs derived from the requirements, written to renders/.
views:
	@mkdir -p $(LEAN_OUT)/spec renders
	$(LEAN) -R . spec/Requirements.lean -o $(LEAN_OUT)/spec/Requirements.olean
	$(LEAN) --run spec/Views.lean
	for f in renders/*.dot; do dot -Tpdf "$$f" -o "$${f%.dot}.pdf"; dot -Tpng "$$f" -o "$${f%.dot}.png"; done

book: views
	$(MAKE) -C book

app-check:
	$(MAKE) -C source check

# Needs a running app (`make run` in another terminal).
browser-check:
	cd source && python3 browser_check.py

run:
	$(MAKE) -C source run

stop:
	$(MAKE) -C source stop

check: spec-check app-check

clean:
	rm -rf .cache/lean renders
	$(MAKE) -C book clean
