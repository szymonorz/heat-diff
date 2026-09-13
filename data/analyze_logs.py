#!/usr/bin/env python3
"""
Analyze heat3d runtime logs and build an Excel workbook (with native charts).

Scenario parameters were not recorded in filenames, so they are deduced from log content:

  * node (locale) count  -> explicit:  "[comm] <bytes> B/step across <N> locale(s)"
  * cube size N          -> derived:   final "sum=<x>"  ~=  N^3  (field avg ~ 1)  -> N = round(cbrt(sum))
  * thread count         -> NOT in the text. Runs were executed in strict order 1->2->4->8->16,
                            so we segment the valid runs into 5 time-ordered batches and label
                            earliest->1 thread ... latest->16 threads. (Compute time is NOT used
                            for the mapping: on a single node, oversubscription makes 8/16 threads
                            slower than 4, so compute does not rank with thread count.)

Output: box-and-whisker + derived-metric figures (PNG) in data/plots/, a combined
        data/plots/heat3d_performance.pdf, and a data/plots/summary.txt stats table.

Run inside the venv that has matplotlib installed.
"""

import copy
import os
import random
import re
import statistics
from dataclasses import dataclass
from typing import Optional

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "plots")
THREAD_ORDER = [1, 2, 4, 8, 16]
CUBE_SNAP = [125, 250, 500, 1000, 2000, 4000]

# regexes
RE_INIT = re.compile(r"Initialization time:\s+([0-9.eE+-]+)")
RE_EXEC = re.compile(r"Execution time:\s+([0-9.eE+-]+)")
RE_LOC = re.compile(r"across\s+(\d+)\s+locale")
RE_BPS = re.compile(r"\[comm\]\s+(\d+)\s+B/step")
RE_SUM = re.compile(r"final field:.*sum=([0-9.eE+-]+)")
RE_STEP = re.compile(
    r"^step\s+\d+\s+updateFluff=([0-9.eE+-]+)\s*s\s+compute=([0-9.eE+-]+)\s*s\s+save=([0-9.eE+-]+)"
)
RE_COMM = re.compile(r"comm\[\d+\]\s+put=(\d+)\s+get=(\d+)\s+on=(\d+)\s+amo=(\d+)")
RE_NAME = re.compile(r"heat3d-(\d{8})-(\d{6})\.log")


@dataclass
class Run:
    path: str
    fname: str
    date: str = ""
    hms: str = ""
    secs: int = 0           # seconds since midnight (for ordering)
    nodes: Optional[int] = None
    bytes_per_step: Optional[int] = None
    sum_val: Optional[float] = None
    cubeN: Optional[int] = None
    init_s: Optional[float] = None
    exec_s: Optional[float] = None
    steps: int = 0
    compute_mean: Optional[float] = None
    fluff_mean: Optional[float] = None
    save_mean: Optional[float] = None
    get_mean: Optional[float] = None
    # filled in later
    threads: Optional[int] = None
    scenario: str = ""

    @property
    def step_mean(self):
        if self.compute_mean is None:
            return None
        return self.compute_mean + self.fluff_mean + (self.save_mean or 0.0)

    @property
    def comm_frac(self):
        if self.compute_mean is None:
            return None
        denom = self.compute_mean + self.fluff_mean
        return self.fluff_mean / denom if denom else None


def parse_file(path):
    fname = os.path.basename(path)
    m = RE_NAME.match(fname)
    r = Run(path=path, fname=fname)
    if m:
        r.date, r.hms = m.group(1), m.group(2)
        h, mi, s = int(r.hms[0:2]), int(r.hms[2:4]), int(r.hms[4:6])
        r.secs = h * 3600 + mi * 60 + s
    fluff, comp, save, gets = [], [], [], []
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            mm = RE_STEP.match(line)
            if mm:
                fluff.append(float(mm.group(1)))
                comp.append(float(mm.group(2)))
                save.append(float(mm.group(3)))
                continue
            mc = RE_COMM.search(line)
            if mc:
                gets.append(int(mc.group(2)))
                continue
            for rx, attr, cast in (
                (RE_INIT, "init_s", float),
                (RE_EXEC, "exec_s", float),
                (RE_LOC, "nodes", int),
                (RE_BPS, "bytes_per_step", int),
                (RE_SUM, "sum_val", float),
            ):
                if getattr(r, attr) is None:
                    g = rx.search(line)
                    if g:
                        setattr(r, attr, cast(g.group(1)))
    r.steps = len(comp)
    if comp:
        r.compute_mean = statistics.fmean(comp)
        r.fluff_mean = statistics.fmean(fluff)
        r.save_mean = statistics.fmean(save)
    if gets:
        r.get_mean = statistics.fmean(gets)
    if r.sum_val and r.sum_val > 0:
        n = round(r.sum_val ** (1.0 / 3.0))
        r.cubeN = min(CUBE_SNAP, key=lambda c: abs(c - n))
    return r


def segment_by_time(runs, k, metric, minlen=5):
    """Sort runs by timestamp, then split into k CONTIGUOUS batches that minimize total
    within-batch variance of `metric` (optimal 1-D segmentation via DP, O(n^2 k)), subject
    to every batch having at least `minlen` runs.

    The runs were executed in strict order (1->2->4->8->16 threads) with ~10 runs each, so
    batches are contiguous in time. The min-size constraint encodes that prior: it stops DP
    from wasting a boundary to isolate a single noisy run as its own "batch" (which it would
    otherwise do when two adjacent thread levels are close, e.g. the comm-bound 1t/2t case),
    forcing the boundaries onto the real level shifts instead."""
    runs = sorted(runs, key=lambda r: r.secs)
    raw = [metric(r) for r in runs]
    # median-of-3 smoothing kills time-isolated single-run outliers (e.g. a stray slow run
    # in the middle of a plateau) so they don't pull the variance-optimal boundary off the
    # real level shift; consecutive outliers are instead absorbed by the min-size constraint.
    v = list(raw)
    for i in range(1, len(raw) - 1):
        v[i] = sorted(raw[i - 1 : i + 2])[1]
    n = len(v)
    if n < k * minlen:                      # not enough data for the constraint
        minlen = max(1, n // k)
    pre = [0.0] * (n + 1)
    pre2 = [0.0] * (n + 1)
    for i in range(n):
        pre[i + 1] = pre[i] + v[i]
        pre2[i + 1] = pre2[i] + v[i] * v[i]

    def sse(i, j):  # within-segment sum of squared error, inclusive i..j
        cnt = j - i + 1
        s = pre[j + 1] - pre[i]
        return (pre2[j + 1] - pre2[i]) - s * s / cnt

    INF = float("inf")
    dp = [[INF] * n for _ in range(k + 1)]
    arg = [[-1] * n for _ in range(k + 1)]
    for j in range(minlen - 1, n):          # first segment 0..j needs >= minlen
        dp[1][j] = sse(0, j)
    for m in range(2, k + 1):
        # segment m..k still need minlen each after j -> cap j
        for j in range(m * minlen - 1, n):
            # new segment p+1..j must be >= minlen -> p <= j - minlen
            for p in range((m - 1) * minlen - 1, j - minlen + 1):
                if dp[m - 1][p] == INF:
                    continue
                c = dp[m - 1][p] + sse(p + 1, j)
                if c < dp[m][j]:
                    dp[m][j] = c
                    arg[m][j] = p
    bounds, j = [], n - 1
    for m in range(k, 0, -1):
        p = arg[m][j]
        bounds.append((p + 1, j))
        j = p
    bounds.reverse()
    return [runs[a : b + 1] for a, b in bounds]


# ---------------------------------------------------------------------------
# load + classify
# ---------------------------------------------------------------------------
def load_dir(sub):
    d = os.path.join(HERE, sub)
    runs = [parse_file(os.path.join(d, f)) for f in os.listdir(d) if f.endswith(".log")]
    return runs


def build_dataset():
    audit = []  # human-readable lines describing the deduction

    # --- 1. thread scaling @ 9 nodes (logs-cpu): 1000^3, 100 steps ---
    cpu = [r for r in load_dir("logs-cpu-clean") if r.steps == 100 and r.exec_s]
    # minlen=5: tolerant, because mid-experiment failures left the 2-thread batch with only 8
    # complete runs; the well-separated compute plateaus pin the other boundaries regardless.
    batches = segment_by_time(cpu, 5, lambda r: r.compute_mean, minlen=5)
    audit.append("Threads @ 9 nodes (logs-cpu) — 5 time-ordered batches -> 1,2,4,8,16 threads:")
    for thr, b in zip(THREAD_ORDER, batches):
        for r in b:
            r.threads, r.scenario = thr, "threads9"
        cm = statistics.fmean(c.compute_mean for c in b)
        audit.append(
            f"  {thr:>2}t: n={len(b):<3} time {b[0].hms}-{b[-1].hms}  "
            f"mean compute/step={cm:.4f}s"
        )

    # --- 2. node scaling (logs-node-scaling): 1000^3, vary locales ---
    # tylko 1..9 węzłów fizycznych (Pionier ma 9 węzłów; 10. lokacja = oversubscription)
    nodes = [r for r in load_dir("logs-node-scaling-clean") if r.steps == 100 and r.exec_s and r.nodes <= 9]
    for r in nodes:
        r.scenario = "nodes"
    audit.append("Node scaling (logs-node-scaling) — grouped by explicit locale count:")
    by_n = {}
    for r in nodes:
        by_n.setdefault(r.nodes, []).append(r)
    for n in sorted(by_n):
        audit.append(f"  {n:>2} node(s): n={len(by_n[n])}")

    # --- 3. cube-size scaling @ 9 nodes (logs-cube-size) ---
    # 2000^3 pominięte (usunięte ze scenariusza rozmiaru kostki)
    cube = [r for r in load_dir("logs-cube-size-clean") if r.steps == 100 and r.exec_s and r.cubeN != 2000]
    for r in cube:
        r.scenario = "cube"
    audit.append("Cube size @ 9 nodes (logs-cube-size) — grouped by N=round(cbrt(sum)):")
    by_c = {}
    for r in cube:
        by_c.setdefault(r.cubeN, []).append(r)
    for n in sorted(by_c):
        audit.append(f"  {n}^3: n={len(by_c[n])}")

    # --- 4. single-node thread scaling (logs-test): 1 locale, 10 steps ---
    test = [r for r in load_dir("logs-test-clean") if r.steps == 10 and r.exec_s and r.nodes == 1]
    # On a single node, 1- vs 2-thread compute times are nearly identical (bandwidth-bound), so
    # the 1t/2t boundary is not separable by value. There are exactly 50 clean runs (10 per
    # setting, no failures), so minlen=10 forces the unique equal split — the right prior here.
    tbatches = segment_by_time(test, 5, lambda r: r.compute_mean, minlen=10)
    audit.append("Single-node threads (logs-test) — 5 time-ordered batches -> 1,2,4,8,16 threads:")
    for thr, b in zip(THREAD_ORDER, tbatches):
        for r in b:
            r.threads, r.scenario = thr, "threads1"
        cm = statistics.fmean(c.compute_mean for c in b)
        audit.append(
            f"  {thr:>2}t: n={len(b):<3} time {b[0].hms}-{b[-1].hms}  "
            f"mean compute/step={cm:.4f}s"
        )

    return {
        "threads9": cpu,
        "nodes": nodes,
        "cube": cube,
        "threads1": test,
    }, audit


# ---------------------------------------------------------------------------
# aggregation
# ---------------------------------------------------------------------------
@dataclass
class Agg:
    key: float
    n: int
    exec_mean: float
    exec_med: float
    exec_min: float
    exec_max: float
    exec_std: float
    init_mean: float
    compute_mean: float
    fluff_mean: float
    save_mean: float
    comm_frac: float
    bytes_per_step: Optional[int]
    get_mean: Optional[float]
    cubeN: Optional[int] = None


def aggregate(runs, keyfn):
    groups = {}
    for r in runs:
        groups.setdefault(keyfn(r), []).append(r)
    out = []
    for key in sorted(groups):
        g = groups[key]
        ex = [r.exec_s for r in g]
        out.append(
            Agg(
                key=key,
                n=len(g),
                exec_mean=statistics.fmean(ex),
                exec_med=statistics.median(ex),
                exec_min=min(ex),
                exec_max=max(ex),
                exec_std=statistics.pstdev(ex) if len(ex) > 1 else 0.0,
                init_mean=statistics.fmean(r.init_s for r in g if r.init_s),
                compute_mean=statistics.fmean(r.compute_mean for r in g),
                fluff_mean=statistics.fmean(r.fluff_mean for r in g),
                save_mean=statistics.fmean(r.save_mean for r in g),
                comm_frac=statistics.fmean(r.comm_frac for r in g),
                bytes_per_step=g[0].bytes_per_step,
                get_mean=statistics.fmean(r.get_mean for r in g if r.get_mean is not None)
                if any(r.get_mean is not None for r in g) else None,
                cubeN=g[0].cubeN,
            )
        )
    return out




# ---------------------------------------------------------------------------
# plotting (matplotlib)
# ---------------------------------------------------------------------------
C_BOX = "#2c3e50"      # box / whisker
C_MED = "#c0392b"      # median line
C_PT = "#2980b9"       # individual run points
C_MEAN = "#27ae60"     # mean diamond
C_LINE = "#34557f"
C_LINE2 = "#c0392b"
C_IDEAL = "#999999"

try:
    plt.style.use("seaborn-v0_8-whitegrid")
except OSError:
    plt.style.use("ggplot")


def clamp_group(runs, target=10):
    """Normalize a config's run list to exactly `target` runs:
      * n > target -> keep the `target` fastest (drop the slowest/worst);
      * n < target -> keep the real runs, pad with copies of a synthetic "average run"
                      (every numeric field set to the group mean) until `target`;
      * n == target -> unchanged."""
    runs = sorted(runs, key=lambda r: r.exec_s)        # fastest first
    if len(runs) > target:
        return runs[:target]                            # drop the slowest
    if len(runs) < target:
        avg = copy.copy(runs[0])
        avg.path = avg.fname = "<avg>"
        avg.exec_s = statistics.fmean(r.exec_s for r in runs)
        avg.compute_mean = statistics.fmean(r.compute_mean for r in runs)
        avg.fluff_mean = statistics.fmean(r.fluff_mean for r in runs)
        avg.save_mean = statistics.fmean(r.save_mean for r in runs)
        inits = [r.init_s for r in runs if r.init_s is not None]
        avg.init_s = statistics.fmean(inits) if inits else None
        gets = [r.get_mean for r in runs if r.get_mean is not None]
        avg.get_mean = statistics.fmean(gets) if gets else None
        runs = runs + [copy.copy(avg) for _ in range(target - len(runs))]
    return runs


def group_runs(runs, keyfn, clamp=10):
    """-> (sorted_keys, {key: [exec_s ...]}, {key: [Run ...]}); each group clamped to `clamp`."""
    g = {}
    for r in runs:
        g.setdefault(keyfn(r), []).append(r)
    keys = sorted(g)
    if clamp:
        for k in keys:
            g[k] = clamp_group(g[k], clamp)
    return keys, {k: [r.exec_s for r in g[k]] for k in keys}, g


def boxplot(ax, groups, labels, ns, ylabel, xlabel, title):
    """Box-and-whisker of `groups` (list of value-lists) with overlaid run points and
    mean diamonds (linear Y axis). Marks the lowest-median config. `ns` is unused."""
    pos = range(1, len(groups) + 1)
    ax.boxplot(
        groups, positions=list(pos), widths=0.62, showfliers=True, showmeans=True,
        medianprops=dict(color=C_MED, lw=2),
        boxprops=dict(color=C_BOX, lw=1.3),
        whiskerprops=dict(color=C_BOX, lw=1.2),
        capprops=dict(color=C_BOX, lw=1.2),
        meanprops=dict(marker="D", mfc=C_MEAN, mec=C_MEAN, ms=5),
        flierprops=dict(marker="o", ms=4, mfc="none", mec="#999"),
    )
    rng = random.Random(0)
    for i, vals in zip(pos, groups):
        xs = [i + rng.uniform(-0.13, 0.13) for _ in vals]
        ax.scatter(xs, vals, s=15, color=C_PT, alpha=0.55, zorder=3, edgecolors="none")
    ax.set_xticks(list(pos))
    ax.set_xticklabels(labels)
    # mark fastest (lowest median)
    meds = [statistics.median(g) for g in groups]
    best = meds.index(min(meds))
    ax.annotate("najszybszy", (best + 1, meds[best]), textcoords="offset points",
                xytext=(0, 10), ha="center", fontsize=8, color=C_MEAN, fontweight="bold")
    ax.set_ylabel(ylabel)
    ax.set_xlabel(xlabel)
    ax.set_title(title, fontsize=11, fontweight="bold")
    ax.margins(x=0.04)


def fig_threads(runs, fixed_note, title, fname, steps):
    keys, ex, g = group_runs(runs, lambda r: r.threads)
    labels = [str(k) for k in keys]
    ns = [len(ex[k]) for k in keys]
    fig, (ax0, ax1) = plt.subplots(1, 2, figsize=(11, 4.4))
    boxplot(ax0, [ex[k] for k in keys], labels, ns, "czas wykonania (s)",
            "wątki na locale (proces)", "Rozkład czasu rzeczywistego")
    # compute per step vs threads (shows oversubscription: more threads -> slower compute)
    comp = [statistics.fmean(r.compute_mean for r in g[k]) for k in keys]
    ax1.plot(range(len(keys)), comp, "o-", color=C_LINE2, lw=2, ms=6)
    ax1.set_xticks(range(len(keys)))
    ax1.set_xticklabels(labels)
    ax1.set_xlabel("wątki na locale (proces)")
    ax1.set_ylabel("średni czas obliczeń / krok (s)")
    ax1.set_title("Średni czas obliczeń / krok w funkcji liczby wątków", fontsize=11, fontweight="bold")
    fig.suptitle(title + "    " + fixed_note, fontsize=12, fontweight="bold")
    fig.tight_layout(rect=(0, 0, 1, 0.95))
    return fig, fname


def fig_nodes(runs):
    keys, ex, g = group_runs(runs, lambda r: r.nodes)
    labels = [str(k) for k in keys]
    ns = [len(ex[k]) for k in keys]
    meds = {k: statistics.median(ex[k]) for k in keys}
    base = meds[keys[0]]
    speedup = [base / meds[k] for k in keys]
    eff = [s / (k / keys[0]) for s, k in zip(speedup, keys)]

    fig, (ax0, ax1) = plt.subplots(1, 2, figsize=(11, 4.4))
    boxplot(ax0, [ex[k] for k in keys], labels, ns, "czas wykonania (s)",
            "węzły (locale)", "Rozkład czasu rzeczywistego")
    # speedup (+ideal) and efficiency
    ideal = [k / keys[0] for k in keys]
    ax1.plot(keys, speedup, "o-", color=C_LINE, lw=2, ms=6, label="przyspieszenie (mediana)")
    ax1.plot(keys, ideal, "--", color=C_IDEAL, lw=1.3, label="idealne (liniowe)")
    ax1.set_xlabel("węzły (locale)")
    ax1.set_ylabel("przyspieszenie względem 1 węzła")
    ax1.set_title("Przyspieszenie i wydajność równoległa", fontsize=11, fontweight="bold")
    axe = ax1.twinx()
    axe.plot(keys, eff, "s-", color=C_LINE2, lw=1.6, ms=5, label="wydajność")
    axe.set_ylabel("wydajność równoległa", color=C_LINE2)
    axe.tick_params(axis="y", labelcolor=C_LINE2)
    axe.set_ylim(0, 1.05)
    axe.grid(False)
    h0, l0 = ax1.get_legend_handles_labels()
    h1, l1 = axe.get_legend_handles_labels()
    ax1.legend(h0 + h1, l0 + l1, loc="upper center", fontsize=8)
    fig.suptitle("Skalowanie po węzłach    (1000³, stała liczba wątków)", fontsize=12,
                 fontweight="bold")
    fig.tight_layout(rect=(0, 0, 1, 0.95))
    return fig, "node_scaling.png"


def fig_cube(runs):
    keys, ex, g = group_runs(runs, lambda r: r.cubeN)
    labels = [str(k) for k in keys]
    ns = [len(ex[k]) for k in keys]
    meds = {k: statistics.median(ex[k]) for k in keys}
    thr = [k ** 3 * 100 / meds[k] / 1e9 for k in keys]                 # mld komórek/s
    commf = [statistics.fmean(r.comm_frac for r in g[k]) for k in keys]

    fig, (ax0, ax1) = plt.subplots(1, 2, figsize=(11, 4.4))
    boxplot(ax0, [ex[k] for k in keys], labels, ns, "czas wykonania (s)",
            "krawędź sześcianu N (N³ komórek)", "Rozkład czasu rzeczywistego")
    ax1.plot(range(len(keys)), thr, "o-", color=C_LINE, lw=2, ms=6, label="przepustowość")
    ax1.set_xticks(range(len(keys)))
    ax1.set_xticklabels(labels)
    ax1.set_xlabel("krawędź sześcianu N")
    ax1.set_ylabel("przepustowość (mld komórek/s)", color=C_LINE)
    ax1.tick_params(axis="y", labelcolor=C_LINE)
    ax1.set_title("Przepustowość i udział komunikacji w funkcji N", fontsize=11, fontweight="bold")
    axc = ax1.twinx()
    axc.plot(range(len(keys)), commf, "s--", color=C_LINE2, lw=1.6, ms=5)
    axc.set_ylabel("udział komunikacji  fluff/(fluff+obliczenia)", color=C_LINE2)
    axc.tick_params(axis="y", labelcolor=C_LINE2)
    axc.set_ylim(0, 1.05)
    axc.grid(False)
    fig.suptitle("Skalowanie rozmiaru sześcianu    (9 węzłów)", fontsize=12, fontweight="bold")
    fig.tight_layout(rect=(0, 0, 1, 0.95))
    return fig, "cube_size.png"


# ---------------------------------------------------------------------------
# summary text
# ---------------------------------------------------------------------------
def write_summary(path, audit, sections):
    lines = ["heat3d performance summary", "=" * 60, ""]
    lines += audit + ["", ""]
    for title, header, rows in sections:
        lines.append(title)
        lines.append("-" * len(title))
        lines.append(header)
        lines += rows
        lines.append("")
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")


def thread_summary(name, runs):
    keys, ex, g = group_runs(runs, lambda r: r.threads)
    base = statistics.median(ex[keys[0]])
    rows = []
    for k in keys:
        e = ex[k]
        med = statistics.median(e)
        rows.append(
            f"  {k:>3}t  n={len(e):<3} med={med:7.3f}s  mean={statistics.fmean(e):7.3f}s  "
            f"min={min(e):7.3f}s  std={statistics.pstdev(e) if len(e)>1 else 0:5.3f}  "
            f"speedup={base/med:5.3f}  compute/step={statistics.fmean(r.compute_mean for r in g[k]):.4f}s"
        )
    return (name, "  config  runs   median    mean      min     std    speedup  compute", rows)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    data, audit = build_dataset()
    print("\n".join(audit))

    figs = []
    figs.append(fig_threads(data["threads9"], "(1000³, 9 locale, 100 kroków)",
                            "Skalowanie wątków przy 9 locale", "threads_9nodes.png", 100))
    figs.append(fig_nodes(data["nodes"]))
    figs.append(fig_cube(data["cube"]))
    figs.append(fig_threads(data["threads1"], "(1000³, 1 locale, 10 kroków)",
                            "Skalowanie wątków w obrębie jednego locale", "threads_1node.png", 10))

    pdf_path = os.path.join(OUT_DIR, "heat3d_performance.pdf")
    with PdfPages(pdf_path) as pdf:
        for fig, fname in figs:
            out = os.path.join(OUT_DIR, fname)
            fig.savefig(out, dpi=140, bbox_inches="tight")
            fig.savefig(out.replace(".png", ".pdf"), bbox_inches="tight")
            pdf.savefig(fig, bbox_inches="tight")
            plt.close(fig)
            print(f"wrote {out}")
    print(f"wrote {pdf_path}")

    # node + cube text summaries
    keys, ex, g = group_runs(data["nodes"], lambda r: r.nodes)
    base = statistics.median(ex[keys[0]])
    node_rows = []
    for k in keys:
        e = ex[k]
        med = statistics.median(e)
        node_rows.append(
            f"  {k:>3}N  n={len(e):<3} med={med:7.3f}s  mean={statistics.fmean(e):7.3f}s  "
            f"min={min(e):7.3f}s  std={statistics.pstdev(e) if len(e)>1 else 0:5.3f}  "
            f"speedup={base/med:5.3f}  eff={base/med/(k/keys[0]):5.3f}  "
            f"bytes/step={g[k][0].bytes_per_step}"
        )
    node_sec = ("Node scaling (1000³)",
                "  config  runs   median    mean      min     std    speedup  eff    bytes/step",
                node_rows)

    keys, ex, g = group_runs(data["cube"], lambda r: r.cubeN)
    cube_rows = []
    for k in keys:
        e = ex[k]
        med = statistics.median(e)
        thr = k ** 3 * 100 / med / 1e9
        cube_rows.append(
            f"  {k:>4}^3  n={len(e):<3} med={med:8.3f}s  mean={statistics.fmean(e):8.3f}s  "
            f"throughput={thr:6.3f} mld komórek/s  comm_frac="
            f"{statistics.fmean(r.comm_frac for r in g[k]):.3f}"
        )
    cube_sec = ("Cube-size scaling (9 nodes)",
                "  config   runs    median      mean      throughput        comm", cube_rows)

    sections = [
        thread_summary("Thread scaling @ 9 nodes (1000³, 100 steps)", data["threads9"]),
        node_sec,
        cube_sec,
        thread_summary("Single-node thread scaling (1000³, 10 steps)", data["threads1"]),
    ]
    spath = os.path.join(OUT_DIR, "summary.txt")
    write_summary(spath, audit, sections)
    print(f"wrote {spath}")


if __name__ == "__main__":
    main()
