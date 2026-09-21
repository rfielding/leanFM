LATEX := pdflatex
MAIN := main

.PHONY: all clean

all:
	$(LATEX) -interaction=nonstopmode -halt-on-error $(MAIN).tex
	bibtex $(MAIN)
	makeindex $(MAIN).idx
	$(LATEX) -interaction=nonstopmode -halt-on-error $(MAIN).tex
	$(LATEX) -interaction=nonstopmode -halt-on-error $(MAIN).tex

clean:
	rm -f $(MAIN).aux $(MAIN).bcf $(MAIN).bbl $(MAIN).blg $(MAIN).idx \
		$(MAIN).ilg $(MAIN).ind $(MAIN).lof $(MAIN).log $(MAIN).lot \
		$(MAIN).out $(MAIN).run.xml $(MAIN).toc $(MAIN).pdf
	rm -f chapters/*.aux
