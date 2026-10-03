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

Solves the 3D heat equation on a `StencilDist` domain with a hot slab along one face. Each step, every locale writes **only its own block** to a local binary dump (`dumpDir/frame_<step>_loc_<id>.bin`) — no gather, no rendering on the compute path. Rendering happens afterward in `src/aggregate3d.chpl`, a single-locale post-processor that reassembles the dumps and reuses the `ImageUtils` voxel renderer (perspective projection + edge wireframe).

| Parameter | Default | Description |
|-----------|---------|-------------|
| `nx`, `ny`, `nz` | 20 | Grid dimensions |
| `numSteps` | 100 | Time steps (one dumped frame per step) |
| `alpha` | 0.25 | Thermal diffusivity |
| `hotThickness` | 2 | Thickness of the hot slab |
| `dumpDir` | frames | Per-locale dump directory (created on each host) |
| `debug` | false | Print GASNet comm diagnostics |

A ping-pong variant, `src/3d_pingpong.chpl`, is identical except it uses alternating buffer roles (`writeToU = step%2==1`) instead of the `un <=> u` swap; it is a reference variant, not used in the measurements.

3D renderer options (module `ImageUtils`):

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-sImageUtils.render` | false | Enable MP4 output |
| `movieName` | heat.mp4 | Output filename (pass `--movieName=heat3d.mp4` to keep the old name) |
| `imageH`, `imageW` | 512 | Frame resolution |
| `camDist` | 2.0 | Camera distance |
| `rotX`, `rotY` | -0.5, 0.0 | Camera rotation |
| `pointSize` | 3 | Voxel dilation radius |
| `cubeScale` | 1.0 | Cube display scale |

## Performance notes

### Array swap (`un <=> u`) is O(1), not a copy

The 3D solver (`src/3d.chpl`) swaps buffers each step with `un <=> u`. The ping-pong variant (`src/3d_pingpong.chpl`) avoids this per-step swap by alternating buffer roles. It turns out the swap is **not** a meaningful cost: Chapel's array swap operator (`operator <=>` in `$CHPL_HOME/modules/internal/ChapelArray.chpl`) first attempts `doiOptimizedSwap`, which swaps the arrays' internal **data pointers in O(1)**. The O(N) element-wise `forall` copy is only a fallback for distributions that don't implement the optimized path — and `StencilDist` (like `BlockDist`) does implement it. So the swap moves no bulk data and performs no communication; it just swaps each locale's local-buffer pointers.

The amount of data moved is therefore O(1) either way. But the two regimes differ once you cross locales, because `doiOptimizedSwap` runs a `coforall loc in Locales do on loc { ... }` to swap each locale's pointer — that per-step cross-locale on-clause/barrier is not free on a high-latency interconnect:

| Configuration | swap cost / step |
|---|---|
| Single locale, 120³, `--fast` | ≈ 3 µs (≈0.1% of compute) |

The swap moves no bulk data at any scale. Across locales, `doiOptimizedSwap` does run a per-step `coforall loc in Locales do on loc { ... }` to swap each locale's pointer, so the ping-pong variant (`3d_pingpong.chpl`) avoids that small cross-locale coordination step. Even so, on the 1 Gbit/s cluster the per-step wall-clock is dominated by `updateFluff` (halo exchange) and the data dump, so the swap is the smallest term either way.

> Note: the GASNet **udp** conduit `ECONGESTION`-aborts on large halo exchanges under
> many-to-one incast or any packet loss (e.g. 1000³ across 9× 1 Gb nodes dies at step 1). The
> robust fix is the **mpi conduit** (`--conduit mpi`, see below): it carries active messages over
> MPI/TCP, so a flooded/lossy link applies backpressure instead of aborting. On a clean network
> the two conduits perform within noise of each other.

## Prerequisites

- Chapel 2.9.0 (built with `CHPL_COMM=gasnet`; `CHPL_LLVM=none` by default, or `system`/`bundled` via `--llvm`, see below)
- Build tools: `gcc g++ make m4 perl python3 cmake wget` + `gmp.h` (no package manager is
  assumed — the scripts check and tell you the install command for your distro)
- ffmpeg (for video rendering)
- For `--conduit mpi`: nothing extra — MPICH is built from source and distributed automatically

## Cluster build, distribute & run (`--conduit udp|mpi`)

One flag drives the whole pipeline. `udp` (default) is fast on a clean LAN; `mpi` survives
packet loss / incast at scale (see the note above).

```bash
# 1. Build Chapel + distribute the compiled tree to every node in the hostfile.
#    The cluster is homogeneous, so one build on any node runs everywhere.
#    --conduit mpi also auto-builds MPICH (from source) and ships it to all nodes.
./scripts/distribute-chapel.sh                -f hosts.txt -d /home/pionier/chapel
./scripts/distribute-chapel.sh --conduit mpi  -f hosts.txt -d /home/pionier/chapel-mpi

# 2. Compile heat3d, distribute the binaries, and generate a conduit-aware run launcher.
#    Hostfile lists ALL nodes, master first (one locale per node for 1000³ on real hardware).
./scripts/compile-and-distribute.sh                -f hosts-both.txt -d /home/pionier/chapel
./scripts/compile-and-distribute.sh --conduit mpi  -f hosts-both.txt -d /home/pionier/chapel-mpi

# 3. Run via the generated launcher (sets the right env per conduit):
#    udp -> GASNET_SSH_SERVERS;  mpi -> mpirun + per-rank interface wrapper.
/home/pionier/chapel-mpi/run-heat3d.sh --nx=1000 --ny=1000 --nz=1000 --numSteps=100
```

`-d` must match between the two scripts (and differ per conduit so udp/mpi installs coexist).
`build-mpi.sh` and the MPI distribution are idempotent (skipped if already present), so re-runs
are cheap. Systematic measurement series are driven by `scripts/bench.sh` (see below); the
generated `run-<bin>.sh` runs a single configuration.

### Compiler backend (`--llvm none|system|bundled`)

By default Chapel uses its C backend (`CHPL_LLVM=none`). To generate code through LLVM instead,
pass `--llvm` to **both** `distribute-chapel.sh` (or `build-chapel.sh`) and
`compile-and-distribute.sh` — the value must match, just like `--conduit`:

- `none` — C backend (default). No LLVM needed anywhere.
- `system` — use an installed LLVM via `llvm-config` (its major version must be in Chapel's
  supported range, 14–22 for 2.9). Add `--llvm-config /usr/bin/llvm-config-<N>` if it is
  versioned. Needs the LLVM dev packages **only on the build node**
  (`llvm-N-dev clang-N libclang-N-dev libclang-cppN-dev`) — LLVM is a compile-time dependency,
  so the shipped program binaries do **not** link `libLLVM` and run on worker nodes without it.
- `bundled` — build LLVM from source into the Chapel tree (large + slow), for a self-contained
  toolchain that needs no system LLVM even to run `chpl`.

Installing a system LLVM (build node only), pick a major version in range (14–22 for Chapel 2.9):

```bash
# Fedora / RHEL (uses the distro's LLVM if it is in range):
sudo dnf install llvm-devel clang-devel

# Debian / recent Ubuntu (if the distro ships a version in range):
sudo apt-get install -y llvm-16-dev clang-16 libclang-16-dev libclang-cpp16-dev

# Ubuntu 20.04 "focal" and older (distro LLVM maxes at 12, too old) -> LLVM's own apt repo.
# NOTE: llvm.sh is run as root and adds an APT repo + signing key; it is LLVM.org's official
#       installer (https://apt.llvm.org). Only the build node needs this.
wget https://apt.llvm.org/llvm.sh && chmod +x llvm.sh && sudo ./llvm.sh 16
sudo apt-get install -y llvm-16-dev clang-16 libclang-16-dev libclang-cpp16-dev
# then point Chapel at it (versioned llvm-config):  --llvm-config /usr/bin/llvm-config-16
```

`libclang-cpp<N>-dev` is easy to miss — without it Chapel's `printchplenv` fails with
"Could not find the clang library …/libclang-cpp.so". Verify with `llvm-config-<N> --version`.

```bash
# Example: mpi conduit + system LLVM 16 (build node needs the LLVM dev packages first)
./scripts/distribute-chapel.sh     --conduit mpi --llvm system --llvm-config /usr/bin/llvm-config-16 \
                           -f hosts.txt      -d /home/pionier/chapel-mpi-llvm
./scripts/compile-and-distribute.sh --conduit mpi --llvm system --llvm-config /usr/bin/llvm-config-16 \
                           -f hosts-both.txt -d /home/pionier/chapel-mpi-llvm
```

Measured effect on the 3D solver: LLVM gives only a small win (~3–5% on the compute loop, none
on communication) because the stencil is memory-bandwidth-bound; the LLVM major version makes no
reliable difference. Use a distinct `-d` per backend so `none`/`system` installs coexist.

## Benchmark suites (`bench.sh`)

`bench.sh` runs the thesis benchmark families from one configurable entry point and writes,
per suite, the per-run logs plus a `RESULTS.tsv` and a `summary.txt` (median/mean/min/max/std).
Every run emits the thesis-standard `[cfg] threadsPerLocale(requested)=N numLocales=M` header,
so the logs are consumable the same way as the existing `data/logs-*` sets.

Suites (`--suite`, comma-separated or `all`):

| suite | sweeps | fixed |
|-------|--------|-------|
| `threads` | `--threads "1 2 4 8 16"` | `--cube-base`, `--nodes-fixed` |
| `cube` | `--cubes "125 250 500 1000"` | `--thread-fixed`, `--nodes-fixed` |
| `nodes` | `--nodes "1 2 …"` (cluster) | `--cube-base`, `--thread-fixed` |
| `llvm` | each of `--llvm-binaries "path:label …"` | `--cube-base`, `--thread-fixed`, `--nodes-fixed` |

Modes (`--mode`): `local` runs `./<binary> -nl 1` directly; `cluster` runs multilocale **on the
master node**, sourcing the `run-env.sh` that `compile-and-distribute.sh` generated (single source
of the launcher env — conduit, `MPIRUN_CMD`/iface wrapper or `GASNET_SSH_SERVERS`, and the host
list) and using its first *n* hosts, so node count varies freely. Point it at that file with
`--run-env` (default `<workdir>/run-env.sh`); `--chpl-home`/`--mpi-dir` are local-mode only.

Parameters are flags over thesis defaults (`--steps 100`, `--reps 10`, `--alpha 0.25`,
`--dumpevery` large = no frame I/O, …); `./scripts/bench.sh --help` lists them all, and `--dry-run`
prints the planned runs without executing. `--binary` is **optional** (default `heat3d`, which is
what `compile-and-distribute.sh` produces); the `llvm` suite ignores it and uses `--llvm-binaries`.

```bash
# Preview the full plan, no runs:
./scripts/bench.sh --mode local --dry-run

# Local sweeps on this host (its fresh binaries are heat3d_none / heat3d_llvm):
./scripts/bench.sh --mode local --suite threads,cube,llvm --binary heat3d_none \
           --llvm-binaries "heat3d_none:none heat3d_llvm:llvm"

# Full thesis matrix on the cluster (run on the master), 1000³ -- conduit/hosts come from run-env.sh:
./scripts/bench.sh --mode cluster --run-env /home/pionier/.../chapel/run-env.sh \
           --workdir /home/pionier/.../chapel \
           --suite all --cube-base 1000 --nodes "1 2 4 8 9"
```

`bench.sh` only *runs* benchmarks against already-built binaries; pick the compiler backend and
conduit when you build them (`distribute-chapel.sh` / `compile-and-distribute.sh --llvm …`).

## Compiling

```bash
export CHPL_HOME=~/chapel-2.9.0
source $CHPL_HOME/util/setchplenv.bash

cd src
chpl --main-module 3d 3d.chpl -o heat3d
chpl --main-module aggregate3d aggregate3d.chpl ImageUtils.chpl -o aggregate3d
chpl 1d.chpl ImageUtils.chpl -o heat1d
```

## Running

GASNet programs require `-nl` (number of locales) and `GASNET_SSH_SERVERS`:

```bash
export GASNET_SSH_SERVERS=localhost

# 1D
./heat1d -nl 1 --n=100 --numSteps=500 -sImageUtils.render=true

# 3D with rendering
./aggregate3d --render=true --nx=30 --ny=30 --nz=30 --numFrames=50   # renders the dumped frames
```
