LATEX := pdflatex
MAIN := main
DARK := main-dark

.PHONY: all light dark clean

all: light dark

light:
	$(LATEX) -interaction=nonstopmode -halt-on-error $(MAIN).tex
	bibtex $(MAIN)
	makeindex $(MAIN).idx
	$(LATEX) -interaction=nonstopmode -halt-on-error $(MAIN).tex
	$(LATEX) -interaction=nonstopmode -halt-on-error $(MAIN).tex

dark:
	$(LATEX) -jobname=$(DARK) -interaction=nonstopmode -halt-on-error "\def\darkmode{1}\input{$(MAIN).tex}"
	bibtex $(DARK)
	makeindex $(DARK).idx
	$(LATEX) -jobname=$(DARK) -interaction=nonstopmode -halt-on-error "\def\darkmode{1}\input{$(MAIN).tex}"
	$(LATEX) -jobname=$(DARK) -interaction=nonstopmode -halt-on-error "\def\darkmode{1}\input{$(MAIN).tex}"

clean:
	rm -f $(MAIN).aux $(MAIN).bcf $(MAIN).bbl $(MAIN).blg $(MAIN).idx \
		$(MAIN).ilg $(MAIN).ind $(MAIN).lof $(MAIN).log $(MAIN).lot \
		$(MAIN).out $(MAIN).run.xml $(MAIN).toc $(MAIN).pdf \
		$(DARK).aux $(DARK).bcf $(DARK).bbl $(DARK).blg $(DARK).idx \
		$(DARK).ilg $(DARK).ind $(DARK).lof $(DARK).log $(DARK).lot \
		$(DARK).out $(DARK).run.xml $(DARK).toc $(DARK).pdf
	rm -f chapters/*.aux
