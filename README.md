# Heat Diffusion Simulations in Chapel

Finite-difference heat equation solvers in 1D, 2D, and 3D, written in [Chapel](https://chapel-lang.org/) with distributed-memory parallelism via GASNet.

## Simulations

### 1D (`src/1d.chpl`)

Solves the 1D heat equation on a distributed `BlockDist` domain. Two hot regions are placed at the ends of the rod.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `n` | 20 | Number of grid points |
| `numSteps` | 100 | Time steps |
| `alpha` | 0.25 | Thermal diffusivity |

### 2D (`src/2d.chpl`)

Solves the 2D heat equation on a `StencilDist` domain with a configurable heatsink-shaped heat source (base plate with fins).

| Parameter | Default | Description |
|-----------|---------|-------------|
| `nx`, `ny` | 50 | Grid dimensions |
| `numSteps` | 100 | Time steps |
| `alpha` | 0.25 | Thermal diffusivity |
| `heatSourceX`, `heatSourceY` | center | Heat source position |
| `heatSourceTemp` | 2.0 | Heat source temperature |
| `debug` | false | Print GASNet comm diagnostics |

### 3D (`src/3d.chpl`)

Solves the 3D heat equation on a `StencilDist` domain with a hot slab along one face. Each step, every locale writes **only its own block** to a local binary dump (`dumpDir/frame_<step>_loc_<id>.bin`) — no gather, no rendering on the compute path. Rendering happens afterward in `src/aggregate3d.chpl`, a single-locale post-processor that reassembles the dumps and reuses the `Render3D` voxel renderer (perspective projection + edge wireframe).

| Parameter | Default | Description |
|-----------|---------|-------------|
| `nx`, `ny`, `nz` | 20 | Grid dimensions |
| `numSteps` | 100 | Time steps (one dumped frame per step) |
| `alpha` | 0.25 | Thermal diffusivity |
| `hotThickness` | 2 | Thickness of the hot slab |
| `dumpDir` | frames | Per-locale dump directory (created on each host) |
| `debug` | false | Print GASNet comm diagnostics |

A swap-based variant, `src/3d_swap.chpl`, is identical except it uses `un <=> u` each step instead of ping-pong buffering, kept for performance comparison (see Performance notes).

3D renderer options (module `Render3D`):

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-sRender3D.render` | false | Enable MP4 output |
| `movieName` | heat3d.mp4 | Output filename |
| `imageH`, `imageW` | 512 | Frame resolution |
| `camDist` | 2.0 | Camera distance |
| `rotX`, `rotY` | -0.5, 0.0 | Camera rotation |
| `pointSize` | 3 | Voxel dilation radius |
| `cubeScale` | 1.0 | Cube display scale |

## Performance notes

### Array swap (`un <=> u`) is O(1), not a copy

The 3D solver uses ping-pong buffering (`src/3d.chpl`) to avoid a per-step `un <=> u`. It turns out this is **not** a meaningful optimization: Chapel's array swap operator (`operator <=>` in `$CHPL_HOME/modules/internal/ChapelArray.chpl`) first attempts `doiOptimizedSwap`, which swaps the arrays' internal **data pointers in O(1)**. The O(N) element-wise `forall` copy is only a fallback for distributions that don't implement the optimized path — and `StencilDist` (like `BlockDist`) does implement it. So the swap moves no bulk data and performs no communication; it just swaps each locale's local-buffer pointers.

The amount of data moved is therefore O(1) either way. But the two regimes differ once you cross locales, because `doiOptimizedSwap` runs a `coforall loc in Locales do on loc { ... }` to swap each locale's pointer — that per-step cross-locale on-clause/barrier is not free on a high-latency interconnect:

| Configuration | swap cost / step | ping-pong vs swap (total) |
|---|---|---|
| Single locale, 120³, `--fast` | ≈ 3 µs (≈0.1% of compute) | identical |
| 2 locales (udp VMs), 64³, 30 steps | ≈ 0.2–2 ms (noisy) | **0.894 s vs 0.998 s** (~12% faster, 3 reps) |

So ping-pong (`3d.chpl`) is a small but consistent win on this multilocale **udp** setup — it avoids the per-step cross-locale swap coordination. On a real interconnect (InfiniBand/Aries) that overhead shrinks toward the single-locale (negligible) case. Either way, absolute per-step wall-clock is dominated by the data dump (I/O, ~15 ms) and `updateFluff` (halo exchange, ~8–11 ms); the swap is the smallest term.

> Note: the GASNet **udp** conduit `ECONGESTION`-aborts on large halo exchanges (128³ died after 2 steps on the 2-VM cluster). Keep multilocale grids modest (≤64³) on these VMs, or raise `GASNET_NETWORKDEPTH_TOTAL`.

## Prerequisites

- Chapel 2.7.0 (built with `CHPL_COMM=gasnet`, `CHPL_LLVM=none`)
- ffmpeg (for video rendering)

## VM Setup

Scripts are provided to run everything in a QEMU VM (Ubuntu 20.04):

```bash
# 1. Prepare cloud image and cloud-init config
./setup-vm.sh

# 2. Launch the VM (graphical or headless)
./start-vm.sh              # GTK window
./start-vm.sh headless     # console only

# 3. SSH into the VM
ssh -p 2222 chapel@localhost

# 4. Build Chapel inside the VM
./build-chapel.sh
```

## Compiling

```bash
export CHPL_HOME=~/chapel-2.7.0
source $CHPL_HOME/util/setchplenv.bash

cd src
chpl --main-module 3d 3d.chpl Render3D.chpl ImageUtils.chpl -o heat3d
chpl 1d.chpl ImageUtils.chpl -o heat1d
```

## Running

GASNet programs require `-nl` (number of locales) and `GASNET_SSH_SERVERS`:

```bash
export GASNET_SSH_SERVERS=localhost

# 1D
./heat1d -nl 1 --n=100 --numSteps=500 -sImageUtils.render=true

# 3D with rendering
./heat3d -nl 1 --nx=30 --ny=30 --nz=30 --numSteps=50 -sRender3D.render=true
```
