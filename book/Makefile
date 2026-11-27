LATEX := pdflatex
MAIN := main
DARK := main-dark
LIGHT_BUILD := main-build
DARK_BUILD := main-dark-build

.PHONY: all light dark clean ui-tour-check

# A design rule of the book: no undefined references or citations. The build fails on one,
# naming it, instead of printing ?? in the PDF.
no-undefined = if grep -E "(Reference|Citation) .* undefined|There were undefined" $(1).log; then \
	echo "book: undefined reference or citation in $(1).log (listed above)" >&2; exit 1; fi

all: light dark

ui-tour-check:
	python3 ../scripts/check_ui_tour.py

light: ui-tour-check
	$(LATEX) -jobname=$(LIGHT_BUILD) -interaction=nonstopmode -halt-on-error $(MAIN).tex
	bibtex $(LIGHT_BUILD)
	makeindex $(LIGHT_BUILD).idx
	$(LATEX) -jobname=$(LIGHT_BUILD) -interaction=nonstopmode -halt-on-error $(MAIN).tex
	$(LATEX) -jobname=$(LIGHT_BUILD) -interaction=nonstopmode -halt-on-error $(MAIN).tex
	@$(call no-undefined,$(LIGHT_BUILD))
	mv $(LIGHT_BUILD).pdf $(MAIN).pdf

dark: ui-tour-check
	$(LATEX) -jobname=$(DARK_BUILD) -interaction=nonstopmode -halt-on-error "\def\darkmode{1}\input{$(MAIN).tex}"
	bibtex $(DARK_BUILD)
	makeindex $(DARK_BUILD).idx
	$(LATEX) -jobname=$(DARK_BUILD) -interaction=nonstopmode -halt-on-error "\def\darkmode{1}\input{$(MAIN).tex}"
	$(LATEX) -jobname=$(DARK_BUILD) -interaction=nonstopmode -halt-on-error "\def\darkmode{1}\input{$(MAIN).tex}"
	@$(call no-undefined,$(DARK_BUILD))
	mv $(DARK_BUILD).pdf $(DARK).pdf

clean:
	rm -f $(MAIN).aux $(MAIN).bcf $(MAIN).bbl $(MAIN).blg $(MAIN).idx \
		$(MAIN).ilg $(MAIN).ind $(MAIN).lof $(MAIN).log $(MAIN).lot \
		$(MAIN).out $(MAIN).run.xml $(MAIN).toc $(MAIN).pdf \
		$(DARK).aux $(DARK).bcf $(DARK).bbl $(DARK).blg $(DARK).idx \
		$(DARK).ilg $(DARK).ind $(DARK).lof $(DARK).log $(DARK).lot \
		$(DARK).out $(DARK).run.xml $(DARK).toc $(DARK).pdf
	rm -f $(LIGHT_BUILD).* $(DARK_BUILD).*
	rm -f chapters/*.aux
