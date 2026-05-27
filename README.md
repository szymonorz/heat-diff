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

Solves the 3D heat equation on a `StencilDist` domain with a hot slab along one face. Includes a 3D voxel renderer with perspective projection and edge wireframe.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `nx`, `ny`, `nz` | 20 | Grid dimensions |
| `numSteps` | 100 | Time steps |
| `subSteps` | 10 | Sub-iterations per render frame |
| `alpha` | 0.25 | Thermal diffusivity |
| `hotThickness` | 2 | Thickness of the hot slab |
| `debug` | false | Print GASNet comm diagnostics |

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
