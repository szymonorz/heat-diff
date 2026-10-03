#!/usr/bin/env bash
# Panel ewolucji dyfuzji 2D WYŁĄCZNIE z wbudowanego renderera programu Chapel (src/2d.chpl).
# Program renderuje pole 2D do MP4 (ImageUtils rank-2 heatmap -> mediaPipe/ffmpeg);
# z MP4 wybieramy 4 klatki i układamy je w panel imagemagickiem. Bez Pythona.
set -euo pipefail
cd "$(dirname "$0")/.."
chpl --fast --main-module 2d src/2d.chpl src/ImageUtils.chpl -o heat2d_local
./heat2d_local --nx=160 --ny=160 --numSteps=900 --renderEvery=9 --render=true \
    --movieName=heat2d_local.mp4 --imageHeight=512 --imageWidth=512
ffmpeg -y -i heat2d_local.mp4 -vf "select='eq(n,0)+eq(n,20)+eq(n,50)+eq(n,100)'" -vsync 0 /tmp/h2dl_%02d.png
magick montage \
  \( /tmp/h2dl_01.png -set label 'krok 0'   \) \
  \( /tmp/h2dl_02.png -set label 'krok 180' \) \
  \( /tmp/h2dl_03.png -set label 'krok 450' \) \
  \( /tmp/h2dl_04.png -set label 'krok 900' \) \
  -tile 4x1 -geometry 240x240+6+6 -background white -bordercolor white -border 4 \
  -pointsize 20 thesis/figures/diffusion_2d.png
echo "zapisano thesis/figures/diffusion_2d.png"
