#!/usr/bin/env python3
"""Wykres skalowania wątkowego dla dziedziny 1000^3 na pojedynczym węźle Pionier
(1 locale, Chapel 2.9, kanał MPI). Dane parsowane bezpośrednio z logów
data/logs-test-clean/ (zrekonstruowane [cfg] threadsPerLocale + Execution time).

Uruchamiać z venv z matplotlib."""
import os
import re
import glob
import statistics as st
import collections
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "logs-test-clean")
PLOTS = os.path.join(HERE, "plots")
THESIS_FIG = os.path.join(os.path.dirname(HERE), "thesis", "figures")
os.makedirs(PLOTS, exist_ok=True)
os.makedirs(THESIS_FIG, exist_ok=True)

C_BOX, C_MED, C_PT, C_MEAN = "#2c3e50", "#c0392b", "#2980b9", "#27ae60"
C_LINE, C_LINE2, C_IDEAL = "#34557f", "#c0392b", "#999999"
try:
    plt.style.use("seaborn-v0_8-whitegrid")
except OSError:
    plt.style.use("ggplot")

# parsowanie logów logs-test-clean: [cfg] threadsPerLocale(requested)=T + Execution time
rows = collections.defaultdict(list)
for path in sorted(glob.glob(os.path.join(DATA, "*.log"))):
    with open(path, encoding="utf-8", errors="replace") as fh:
        txt = fh.read()
    m_t = re.search(r"\[cfg\].*threadsPerLocale\(requested\)=([\d]+)", txt)
    m_e = re.search(r"Execution time:\s*([\d.]+)\s*s", txt)
    if not (m_t and m_e):
        continue
    T = int(m_t.group(1))
    rows[T].append(float(m_e.group(1)))

keys = sorted(rows)                       # [1,2,4,8,16]
groups = [rows[k] for k in keys]
meds = [st.median(g) for g in groups]
base = meds[0]
speedup = [base / m for m in meds]
eff = [s / k for s, k in zip(speedup, keys)]

fig, (ax0, ax1) = plt.subplots(1, 2, figsize=(11, 4.4))

# --- lewy panel: rozkład czasu wykonania (box + punkty + średnia) ---
pos = range(1, len(keys) + 1)
ax0.boxplot(groups, positions=list(pos), widths=0.62, showmeans=True,
            medianprops=dict(color=C_MED, lw=2),
            boxprops=dict(color=C_BOX, lw=1.3),
            whiskerprops=dict(color=C_BOX, lw=1.2),
            capprops=dict(color=C_BOX, lw=1.2),
            meanprops=dict(marker="D", mfc=C_MEAN, mec=C_MEAN, ms=5),
            flierprops=dict(marker="o", ms=4, mfc="none", mec="#999"))
import random
rng = random.Random(0)
for i, vals in zip(pos, groups):
    xs = [i + rng.uniform(-0.13, 0.13) for _ in vals]
    ax0.scatter(xs, vals, s=15, color=C_PT, alpha=0.55, zorder=3, edgecolors="none")
best = meds.index(min(meds))
ax0.annotate("najszybszy", (best + 1, meds[best]), textcoords="offset points",
             xytext=(0, 10), ha="center", fontsize=8, color=C_MEAN, fontweight="bold")
ax0.set_xticks(list(pos)); ax0.set_xticklabels([str(k) for k in keys])
ax0.set_ylabel("czas wykonania (s)")
ax0.set_xlabel("żądana liczba wątków (= maxTaskPar)")
ax0.set_title("Rozkład czasu wykonania", fontsize=11, fontweight="bold")

# --- prawy panel: przyspieszenie (+ideał liniowy) i wydajność równoległa ---
ax1.plot(keys, speedup, "o-", color=C_LINE, lw=2, ms=6, label="przyspieszenie (mediana)")
ax1.plot(keys, keys, "--", color=C_IDEAL, lw=1.3, label="idealne (liniowe)")
ax1b = ax1.twinx()
ax1b.plot(keys, eff, "s-", color=C_LINE2, lw=1.6, ms=5, label="wydajność $E$")
ax1b.set_ylim(0, 1.05)
ax1b.set_ylabel("wydajność równoległa $E$", color=C_LINE2)
ax1b.tick_params(axis="y", colors=C_LINE2)
ax1.set_xlabel("żądana liczba wątków")
ax1.set_ylabel("przyspieszenie $S$")
ax1.set_title("Przyspieszenie i wydajność", fontsize=11, fontweight="bold")
ax1.set_xticks(keys)
ax1.legend(loc="upper left", fontsize=9)
ax1b.legend(loc="upper right", fontsize=9)
fig.suptitle("Skalowanie wątkowe, dziedzina $1000^3$ (1 węzeł Pionier, 10 powtórzeń)",
             fontsize=12, fontweight="bold")
fig.tight_layout(rect=(0, 0, 1, 0.95))
out = os.path.join(PLOTS, "threads_1000.png")
fig.savefig(out, dpi=140, bbox_inches="tight")
fig.savefig(os.path.join(THESIS_FIG, "threads_1000.pdf"), bbox_inches="tight")
fig.savefig(os.path.join(THESIS_FIG, "threads_1000.png"), dpi=140, bbox_inches="tight")
print("wrote", out, "+ thesis figures/threads_1000.pdf")
print("keys:", keys, "| meds:", [round(m, 3) for m in meds])
print("speedup:", [round(s, 3) for s in speedup])
plt.close(fig)
