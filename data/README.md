# Benchmark logs

Runtime logs from the `heat3d` solver on the **Pionier cluster** (9 identical nodes, Intel Core
i7-12700K 12c/20t, 32 GiB, 1 Gbit/s Ethernet, homogeneous Ubuntu), gathered with
`scripts/bench.sh` over the **mpi conduit**. Each log is named `<binary>-<YYYYmmdd-HHMMSS>.log`
and is self-describing: it opens with a `[cfg] threadsPerLocale(requested)=N numLocales=M` line,
records per-step `updateFluff` / `compute` / `save` timings, and ends with `Execution time:` and
the `final field: … sum=…`. The swept parameter is recovered from this content, so it does not
appear in the filename. `analyze_logs.py` turns these directories into the box-and-whisker and
derived-metric plots; `aggregate_bench.py` produces the per-suite `RESULTS.tsv` / `summary.txt`.

The `-clean` suffix means outlier or aborted runs were pruned, so a configuration may have
slightly fewer than its nominal ten repetitions.

**Common parameters** (unless a directory note says otherwise): Chapel 2.9.0, C backend
(`CHPL_LLVM=none`), `--alpha 0.25`, `--numSteps 100`, no frame I/O (`--dumpEvery` > steps), and
**ten repetitions per configuration** (the thesis reports the median). Pionier nodes expose 20
hardware threads, but qthreads caps a locale at **16** (the eight P-cores, 2-way SMT), so a
requested count of 20 runs as 16 effective threads.

All runs below are launched from the master node in `--mode cluster`; `bench.sh` reads the
conduit and host list from the `run-env.sh` that `compile-and-distribute.sh` generated
(`--run-env <install>/run-env.sh --workdir <install>`, omitted here for brevity).

## logs-cpu-clean — thread scaling

Threads-per-locale swept `1 2 4 8 16` at a fixed 1000³ grid on all 9 nodes.

```bash
./scripts/bench.sh --mode cluster --suite threads --cube-base 1000 --threads "1 2 4 8 16"
```

## logs-cube-size-clean — cube-size sweep

Grid edge swept `125 250 500 1000 2000` on all 9 nodes at the default thread count (20 → 16).

```bash
./scripts/bench.sh --mode cluster --suite cube --cubes "125 250 500 1000 2000"
```

## logs-node-scaling-clean — node (locale) scaling

Locale count swept `1 … 9` at a fixed 1000³ grid and the default thread count (20 → 16).

```bash
./scripts/bench.sh --mode cluster --suite nodes --cube-base 1000 --nodes "1 2 3 4 5 6 7 8 9"
```

## logs-test-clean — single-node thread scaling

Single-locale thread scaling: 1 locale, 1000³, **10 steps**, threads `1 2 4 8 16`. This is the
data behind the single-node thread-scaling figure (`thesis/figures/threads_1000.pdf`, plotted by
`plot_threads_1000.py`).

```bash
./scripts/bench.sh --mode cluster --suite threads --nodes-fixed 1 \
    --cube-base 1000 --threads "1 2 4 8 16" --steps 10
```

## logs-llvm — compiler-backend comparison

Two binaries of the same program run on all 9 nodes at 100³, 100 steps, 10 reps: `none/` is the
C backend (`CHPL_LLVM=none`), `llvm/` is the LLVM backend (`CHPL_LLVM=system`, LLVM 19.1.7).
Build the second binary with `--llvm system` (see the repo README), then:

```bash
./scripts/bench.sh --mode cluster --suite llvm --cube-base 100 \
    --llvm-binaries "heat3d_none:none heat3d_llvm:llvm"
```
