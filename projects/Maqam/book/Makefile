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
	rm -f *.aux *.log *.out *.toc $(MAIN).pdf $(DARK).pdf
