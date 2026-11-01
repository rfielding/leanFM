LATEX := pdflatex
MAIN := main
DARK := main-dark

.PHONY: all light dark clean

all: light dark

light:
	$(LATEX) -interaction=nonstopmode -halt-on-error $(MAIN).tex
	$(LATEX) -interaction=nonstopmode -halt-on-error $(MAIN).tex

dark:
	$(LATEX) -jobname=$(DARK) -interaction=nonstopmode -halt-on-error "\def\darkmode{1}\input{$(MAIN).tex}"
	$(LATEX) -jobname=$(DARK) -interaction=nonstopmode -halt-on-error "\def\darkmode{1}\input{$(MAIN).tex}"

clean:
	rm -f $(MAIN).aux $(MAIN).log $(MAIN).out $(MAIN).toc $(MAIN).pdf $(DARK).aux $(DARK).log $(DARK).out $(DARK).toc $(DARK).pdf
