# GoServer project: specification checks, derived views, book and app.
# Requires the LeanFM installation two directories up (`make build` there).
LEANFM := $(abspath ../..)

.PHONY: all check spec-check views book app-check run stop browser-check tour clean

all: check views book

# Canonical LeanFM project check: compiles spec/Requirements.lean and
# spec/Implementation.lean in the sandbox, validates both and the proto,
# and derives spec/tasks.json.
spec-check:
	cd $(LEANFM) && python3 scripts/chatui_specification.py $(CURDIR) \
	  Project.Requirements.requirements Project.Implementation.implementation

# State-machine figures for every task, derived from spec/tasks.json into renders/.
views:
	python3 book/views.py

book: views
	$(MAKE) -C book

app-check:
	$(MAKE) -C source check

# Two users in headless Chrome (CHROME=/path/to/chrome to override); starts its own app.
browser-check:
	cd source && python3 browser_check.py

# Replays the usage scenarios and refreshes book/assets/tour and book/tour.tex.
tour:
	$(MAKE) -C source book-tour

run:
	$(MAKE) -C source run

stop:
	$(MAKE) -C source stop

check: spec-check app-check

clean:
	rm -rf renders
	$(MAKE) -C book clean
	$(MAKE) -C source clean
