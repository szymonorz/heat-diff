#!/usr/bin/env bash
# Kompilacja pracy do PDF (thesis/main.pdf).
#
# Uzycie:
#   ./build.sh          # zbuduj main.pdf (pdflatex przez latexmk, tyle przebiegow ile trzeba)
#   ./build.sh clean    # najpierw pelne czyszczenie plikow pomocniczych, potem budowa
#
# Bibliografia jest reczna (\begin{thebibliography}), wiec bibtex/biber nie jest potrzebny.
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "clean" ]]; then
  latexmk -C
fi

latexmk -pdf -interaction=nonstopmode -halt-on-error main.tex

echo "gotowe: $(pwd)/main.pdf"
