# End-to-end: build, distribute & run heat3d on the cluster

Walkthrough for building and distributing Chapel, compiling and distributing the `heat3d`
program, and running it across the cluster — all driven by the repo's scripts. Everything runs
from the **master node**, where this repository is checked out (so `scripts/`, `src/` and
`data/` are present).

Target cluster: 9 identical nodes (Intel Core i7-12700K, 12c/20t, 32 GiB, 1 Gbit/s Ethernet,
homogeneous Ubuntu), reachable over SSH on port 22. Because the interconnect is a single
1 Gbit/s link, use the **mpi conduit** (`--conduit mpi`): the udp conduit `ECONGESTION`-aborts
under the many-to-one halo-exchange incast at scale. The nodes are homogeneous, so one build
on the master runs everywhere.

Shell settings used throughout (adjust the user and install path to your account):

```bash
NODE_USER=pionier
INSTALL_DIR=/home/pionier/chapel        # the same absolute path on every node
```

The install path must be **identical on all nodes**: Chapel's runtime bakes it into the
binaries' `rpath`, so a mismatch breaks shared-library loading at launch.

## 1. Host files

`distribute-chapel.sh` ships the toolchain to the **worker** nodes; `compile-and-distribute.sh`
needs **all** nodes, master first.

```bash
# workers only (every node except the master)
printf 'lab8-2\nlab8-3\nlab8-4\nlab8-5\nlab8-6\nlab8-7\nlab8-8\nlab8-9\n' > hosts.txt

# all nodes, master first
printf 'lab8-1\nlab8-2\nlab8-3\nlab8-4\nlab8-5\nlab8-6\nlab8-7\nlab8-8\nlab8-9\n' > hosts-both.txt
```

## 2. Build & distribute Chapel (+ MPICH)

Builds Chapel 2.9.0 and MPICH 4.2.3 from source on the master and ships both to every worker
under `$INSTALL_DIR`. **~20–40 min** the first time; re-runs skip the MPICH build.

```bash
CHAPEL_SSH_USER=$NODE_USER \
  bash scripts/distribute-chapel.sh --conduit mpi -f hosts.txt -d "$INSTALL_DIR"
```

To bake in the LLVM backend instead of the default C backend, add
`--llvm system --llvm-config /usr/bin/llvm-config-<N>` (only the build node needs the LLVM dev
packages — see step 6).

## 3. Compile & distribute the program

Compiles `heat3d` plus the `aggregate3d` post-processor and distributes the binaries to all
nodes. Use the **same `--conduit`/`--llvm`** as step 2, and a `-d` distinct from the repo
working copy so the install tree and the sources never overlap.

```bash
CHAPEL_SSH_USER=$NODE_USER \
  bash scripts/compile-and-distribute.sh --conduit mpi -f hosts-both.txt -d "$INSTALL_DIR"
```

Both `<bin>` and `<bin>_real` are copied to every node (multilocale needs both). This also
generates, in `$INSTALL_DIR`, the shared launcher env **`run-env.sh`** plus the `run-heat3d.sh`
and `aggregate-heat3d.sh` wrappers. Re-run this step whenever `src/*.chpl` changes.

## 4. Run across the nodes

The generated wrapper sets the conduit launcher env and runs the program on all locales. Pass
`--dumpDir` an **absolute** path, since workers have a different working directory:

```bash
cd "$INSTALL_DIR"
CHPL_RT_NUM_THREADS_PER_LOCALE=16 ./run-heat3d.sh \
    --nx=1000 --ny=1000 --nz=1000 --numSteps=100 --dumpDir="$INSTALL_DIR/frames"
```

Each locale writes only its own slab to its local disk. Merge the slabs and (optionally) render
a movie afterward:

```bash
./aggregate-heat3d.sh --render=true
```

Frames are gzip-compressed by default; on a large grid with many steps, thin them with
`--dumpEvery=N` (and then pass the aggregator `--numFrames = numSteps/N`) to avoid filling the
node's disk (`ENOSPC`).

## 5. Benchmark suites

`bench.sh` drives the thesis benchmark families (thread scaling, cube-size sweep, node scaling,
and the compiler-backend comparison) and writes, per suite, the per-run logs plus a
`RESULTS.tsv` and `summary.txt`. Run it on the master in `--mode cluster`: it sources the
`run-env.sh` from step 3 for the conduit and host list and varies `-nl` across the sweep itself.

```bash
bash scripts/bench.sh --mode cluster \
     --run-env "$INSTALL_DIR/run-env.sh" --workdir "$INSTALL_DIR" \
     --suite threads,cube,nodes --cube-base 1000 --nodes "1 2 4 8 9" \
     --outdir "$INSTALL_DIR/bench-out"
```

Each run is repeated (`--reps`, default 10) and executed sequentially. Logs are named
`<binary>-<timestamp>.log`, the same convention as `data/logs-*`. `--dry-run` prints the planned
runs without executing; `bash scripts/bench.sh --help` lists every flag (steps, reps, alpha,
thread/cube/node lists, …).

## 6. Compare compiler backends (optional)

LLVM is a compile-time backend. Build a second program binary with the LLVM backend alongside
the default C one, then run the `llvm` suite. Only the **master** needs LLVM installed — the
shipped binaries do not link `libLLVM`, so workers run them without it.

```bash
# one-time: LLVM dev packages on the master, a major version in Chapel 2.9's range (14–22)
sudo apt-get install -y llvm-16-dev clang-16 libclang-16-dev libclang-cpp16-dev

# rebuild the toolchain WITH the LLVM backend and reship it:
CHAPEL_SSH_USER=$NODE_USER \
  bash scripts/distribute-chapel.sh --conduit mpi --llvm system \
       --llvm-config /usr/bin/llvm-config-16 -f hosts.txt -d "$INSTALL_DIR-llvm"

# compile the program with the LLVM backend, under a distinct name:
CHAPEL_SSH_USER=$NODE_USER \
  bash scripts/compile-and-distribute.sh --conduit mpi --llvm system \
       --llvm-config /usr/bin/llvm-config-16 -o heat3d_llvm \
       -f hosts-both.txt -d "$INSTALL_DIR-llvm"

# compare the two backends (build heat3d with the C backend into the same dir as well):
bash scripts/bench.sh --mode cluster --run-env "$INSTALL_DIR-llvm/run-env.sh" \
     --workdir "$INSTALL_DIR-llvm" --suite llvm \
     --llvm-binaries "heat3d:none heat3d_llvm:llvm" --outdir "$INSTALL_DIR-llvm/bench-llvm"
```

Use a distinct `-d` per backend (`none`/`system`) so the two installs coexist. On the 3D solver
the LLVM backend gives only a small win on the compute loop and none on communication, because
the stencil is memory-bandwidth-bound and the multi-node runtime is dominated by halo exchange.
