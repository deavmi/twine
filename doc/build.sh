#!/bin/bash
pandoc -f markdown --number-sections --toc *.md -s -t latex --highlight-style kate
pandoc -f markdown --number-sections --toc *.md -s -t latex --highlight-style kate | pdflatex 
