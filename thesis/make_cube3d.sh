#!/usr/bin/env bash
# Render kostki 3D pola temperatury WYŁĄCZNIE wbudowanym rendererem programu Chapela.
# Program zapisuje zrzuty pola, aggregate3d renderuje je do MP4 (mediaPipe->ffmpeg),
# z którego wycinamy pojedynczą klatkę. Bez żadnego przetwarzania w Pythonie.
set -euo pipefail
cd "$(dirname "$0")/.."
./heat3d_local -nl 1 --nx=64 --ny=64 --nz=64 --numSteps=14000 --dumpEvery=500 --dumpDir=frames3d
./aggregate3d  -nl 1 --render=true --nx=64 --ny=64 --nz=64 --numFrames=28 \
    --dumpDir=frames3d --movieName=cube_hi.mp4 --rotX=0.5 --rotY=0.6 --imageH=1000 --imageW=1000
# klatka końcowa (krok 14000 = klatka 27, licząc od 0) z MP4 wygenerowanego przez program
ffmpeg -y -i cube_hi.mp4 -vf "select='eq(n,27)'" -vsync 0 /tmp/cube_hi.png
convert /tmp/cube_hi.png -trim +repage -bordercolor white -border 20 thesis/figures/heat3d_cube.png
echo "zapisano thesis/figures/heat3d_cube.png"
