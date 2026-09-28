#!/usr/bin/env bash
#
# bench.sh -- run the thesis heat3d benchmark suites with configurable parameters.
#
# Suites (choose with --suite, comma-separated, or "all"):
#   threads : thread scaling at a fixed cube + node count   (sweeps --threads)
#   cube    : cube-size sweep at fixed threads + nodes        (sweeps --cubes)
#   nodes   : node/locale scaling at fixed cube + threads     (sweeps --nodes; cluster)
#   llvm    : compiler-backend comparison, runs each of --llvm-binaries
#
# Modes (--mode):
#   local   : single machine, runs ./<binary> -nl <n> directly (n defaults to 1)
#   cluster : multilocale on the master node; sets the conduit launcher env itself
#             (mpi -> MPIRUN_CMD + iface wrapper; udp -> GASNET_SSH_SERVERS) using the
#             first <n> hosts of --hostfile, so node count can vary freely.
#
# Each run emits the thesis-standard header line
#   [cfg] threadsPerLocale(requested)=<t> numLocales=<n>
# then the solver output, tee'd to a per-suite log. Cube size is recoverable from
# "final field: sum=" and steps from the "step N" lines, exactly as analyze_logs.py expects.
#
# This script RUNS benchmarks against already-built binaries. Build/select the compiler
# backend with distribute-chapel.sh / build-chapel.sh / compile-and-distribute.sh --llvm.
#
set -eo pipefail

# ---------------------------------------------------------------- defaults (override via flags/env)
MODE="${MODE:-local}"                 # local | cluster
SUITE="${SUITE:-all}"                 # threads,cube,nodes,llvm | all
CONDUIT="${CONDUIT:-mpi}"             # mpi | udp  (cluster launcher; also affects PATH)
STEPS="${STEPS:-100}"
REPS="${REPS:-10}"
ALPHA="${ALPHA:-0.25}"
DUMPEVERY="${DUMPEVERY:-1000000}"     # > STEPS  => no frame output
THREADS="${THREADS:-1 2 4 8 16}"      # thread sweep for the 'threads' suite
CUBES="${CUBES:-125 250 500 1000}"    # cube sweep for the 'cube' suite
NODES="${NODES:-1 2}"                 # node sweep for the 'nodes' suite (cluster)
CUBE_BASE="${CUBE_BASE:-}"            # cube for threads/nodes/llvm suites (default 500 local, 1000 cluster)
THREAD_FIXED="${THREAD_FIXED:-}"      # threads for cube/nodes/llvm suites (default: nproc)
NODES_FIXED="${NODES_FIXED:-}"        # locales for threads/cube/llvm suites (default: 1 local, hostfile size cluster)
BINARY="${BINARY:-heat3d}"           # binary name for threads/cube/nodes suites
LLVM_BINARIES="${LLVM_BINARIES:-heat3d_none:none heat3d_llvm:llvm}"  # 'path:label ...' for the llvm suite
WORKDIR="${WORKDIR:-$PWD}"            # dir holding the binaries (cd here before running)
CHPL_HOME_DIR="${CHPL_HOME:-$PWD/chapel-2.9.0}"
MPI_DIR="${MPI_DIR:-$PWD/mpi}"
RUN_ENV="${RUN_ENV:-}"               # cluster: run-env.sh from compile-and-distribute.sh (default: <workdir>/run-env.sh)
OUTDIR="${OUTDIR:-data/bench-$(date +%Y%m%d-%H%M%S)}"
DRY_RUN=false

usage() {
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
    cat <<EOF

Usage: $0 [options]
  --mode local|cluster        (default: $MODE)
  --suite LIST                 threads,cube,nodes,llvm or all (default: $SUITE)
  --conduit mpi|udp            cluster launcher (default: $CONDUIT)
  --steps N                    time steps (default: $STEPS)
  --reps N                     repetitions per point (default: $REPS)
  --alpha F                    diffusivity, timing-neutral (default: $ALPHA)
  --dumpevery N                frame dump interval; keep > steps for no I/O (default: $DUMPEVERY)
  --threads "L1 L2 .."         thread sweep for 'threads' suite (default: $THREADS)
  --cubes "N1 N2 .."           cube sweep for 'cube' suite (default: $CUBES)
  --nodes "N1 N2 .."           node sweep for 'nodes' suite (default: $NODES)
  --cube-base N                cube for threads/nodes/llvm suites (default: 500 local / 1000 cluster)
  --thread-fixed N             threads for cube/nodes/llvm suites (default: nproc)
  --nodes-fixed N              locales for threads/cube/llvm suites (default: 1 local / hostfile size)
  --binary NAME                binary for threads/cube/nodes suites (default: $BINARY)
  --llvm-binaries "p:l .."     'path:label' pairs for the llvm suite (default: $LLVM_BINARIES)
  --workdir DIR                dir containing the binaries (default: \$PWD)
  --chpl-home DIR              (local mode) CHPL_HOME (default: \$PWD/chapel-2.9.0)
  --mpi-dir DIR                (local mode) MPI prefix (default: \$PWD/mpi)
  --run-env FILE               (cluster mode) run-env.sh from compile-and-distribute.sh
                               (default: <workdir>/run-env.sh); supplies CHPL_HOME/PATH/hosts/conduit
  --outdir DIR                 output root (default: data/bench-<timestamp>)
  --dry-run                    print the runs without executing
  -h, --help                   this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --suite) SUITE="$2"; shift 2 ;;
        --conduit) CONDUIT="$2"; shift 2 ;;
        --steps) STEPS="$2"; shift 2 ;;
        --reps) REPS="$2"; shift 2 ;;
        --alpha) ALPHA="$2"; shift 2 ;;
        --dumpevery) DUMPEVERY="$2"; shift 2 ;;
        --threads) THREADS="$2"; shift 2 ;;
        --cubes) CUBES="$2"; shift 2 ;;
        --nodes) NODES="$2"; shift 2 ;;
        --cube-base) CUBE_BASE="$2"; shift 2 ;;
        --thread-fixed) THREAD_FIXED="$2"; shift 2 ;;
        --nodes-fixed) NODES_FIXED="$2"; shift 2 ;;
        --binary) BINARY="$2"; shift 2 ;;
        --llvm-binaries) LLVM_BINARIES="$2"; shift 2 ;;
        --workdir) WORKDIR="$2"; shift 2 ;;
        --chpl-home) CHPL_HOME_DIR="$2"; shift 2 ;;
        --mpi-dir) MPI_DIR="$2"; shift 2 ;;
        --run-env) RUN_ENV="$2"; shift 2 ;;
        --outdir) OUTDIR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1 (use --help)" >&2; exit 1 ;;
    esac
done

[[ "$MODE" == "local" || "$MODE" == "cluster" ]] || { echo "Error: --mode must be local or cluster." >&2; exit 1; }
[[ "$CONDUIT" == "mpi" || "$CONDUIT" == "udp" ]] || { echo "Error: --conduit must be mpi or udp." >&2; exit 1; }

# resolve mode-dependent defaults
[[ -z "$CUBE_BASE" ]]   && { [[ "$MODE" == "local" ]] && CUBE_BASE=500 || CUBE_BASE=1000; }
[[ -z "$THREAD_FIXED" ]] && THREAD_FIXED="$(nproc)"

# activate the toolchain / launcher env
HOSTS=()
if [[ "$MODE" == "cluster" ]]; then
    # cluster delegates ALL launcher env to run-env.sh (single source of truth, generated by
    # compile-and-distribute.sh): CHPL_HOME, PATH, conduit, host list, and set_run_env().
    [[ -z "$RUN_ENV" ]] && RUN_ENV="$WORKDIR/run-env.sh"
    [[ -f "$RUN_ENV" ]] || { echo "Error: cluster mode needs run-env.sh (generated by compile-and-distribute.sh); not found: $RUN_ENV. Pass --run-env." >&2; exit 1; }
    source "$RUN_ENV"
    read -ra HOSTS <<< "${RUN_ALL_HOSTS:-}"
    [[ ${#HOSTS[@]} -gt 0 ]] || { echo "Error: run-env.sh defines no hosts (RUN_ALL_HOSTS empty)." >&2; exit 1; }
    CONDUIT="${RUN_CONDUIT:-$CONDUIT}"   # report the conduit run-env.sh was built for
else
    export CHPL_HOME="$CHPL_HOME_DIR"
    export PATH="$MPI_DIR/bin:$CHPL_HOME/bin/linux64-x86_64:$CHPL_HOME/util:$PATH"
    [[ -f "$CHPL_HOME/util/setchplenv.bash" ]] && source "$CHPL_HOME/util/setchplenv.bash" >/dev/null 2>&1 || true
fi
[[ -z "$NODES_FIXED" ]] && { [[ "$MODE" == "local" ]] && NODES_FIXED=1 || NODES_FIXED=${#HOSTS[@]}; }

mkdir -p "$OUTDIR"
echo ">>> bench: mode=$MODE conduit=$CONDUIT steps=$STEPS reps=$REPS alpha=$ALPHA -> $OUTDIR"

# launcher env for a given locale count: cluster delegates to run-env.sh's set_run_env; local no-op
set_launcher_env() {
    [[ "$MODE" == "local" ]] && return 0
    set_run_env "$1"
}

# run REPS reps of one configuration; logs -> $dir/<prefix>-r<NN>.log
run_point() {
    local bin="$1" cube="$2" threads="$3" nl="$4" dir="$5" prefix="$6"
    mkdir -p "$dir"
    export CHPL_RT_NUM_THREADS_PER_LOCALE="$threads"
    set_launcher_env "$nl"
    local r rr LOG
    for r in $(seq 1 "$REPS"); do
        rr="$(printf 'r%02d' "$r")"
        LOG="$dir/${prefix}-${rr}.log"
        if [[ "$DRY_RUN" == true ]]; then
            echo "DRY: (cd $WORKDIR; CHPL_RT_NUM_THREADS_PER_LOCALE=$threads ./$bin -nl $nl --nx=$cube --ny=$cube --nz=$cube --numSteps=$STEPS --alpha=$ALPHA --dumpEvery=$DUMPEVERY) -> $LOG"
            continue
        fi
        [[ -x "$WORKDIR/$bin" ]] || { echo "  ERROR: $WORKDIR/$bin not found/executable" >&2; return 1; }
        ( cd "$WORKDIR"
          set -o pipefail
          {
            echo "[cfg] threadsPerLocale(requested)=$threads numLocales=$nl"
            ./"$bin" -nl "$nl" --nx="$cube" --ny="$cube" --nz="$cube" \
                     --numSteps="$STEPS" --alpha="$ALPHA" --dumpEvery="$DUMPEVERY" 2>&1
          } | tee "$LOG" >/dev/null )
        echo "    ${prefix} ${rr}: $(grep -m1 'Execution time:' "$LOG" 2>/dev/null || echo 'NO EXEC TIME')"
    done
}

# aggregate a suite dir: group logs by the token before -rNN, emit RESULTS.tsv + summary.txt
aggregate_suite() {
    local dir="$1" title="$2"
    [[ "$DRY_RUN" == true ]] && return 0
    python3 - "$dir" "$title" <<'PY'
import sys, glob, re, statistics as st, os
d,title=sys.argv[1],sys.argv[2]
groups={}
for f in sorted(glob.glob(f"{d}/*-r*.log")):
    b=os.path.basename(f)
    m=re.match(r'(.+)-r\d+\.log$', b)
    if not m: continue
    key=m.group(1)
    t=open(f).read()
    em=re.search(r'Execution time:\s+([0-9.eE+-]+)', t)
    if em: groups.setdefault(key,[]).append(float(em.group(1)))
with open(f"{d}/RESULTS.tsv","w") as o:
    o.write("point\trep\texec_s\n")
    for k in sorted(groups):
        for i,v in enumerate(groups[k],1): o.write(f"{k}\t{i}\t{v}\n")
lines=[f"{title}",""]
lines.append(f"{'point':<22}{'n':>3}{'median':>10}{'mean':>10}{'min':>9}{'max':>9}{'std':>8}")
lines.append("-"*71)
def keyf(k):
    m=re.search(r'(\d+)',k); return (int(m.group(1)) if m else 0, k)
for k in sorted(groups,key=keyf):
    xs=groups[k]
    lines.append(f"{k:<22}{len(xs):>3}{st.median(xs):>10.3f}{st.mean(xs):>10.3f}{min(xs):>9.3f}{max(xs):>9.3f}{(st.pstdev(xs) if len(xs)>1 else 0):>8.3f}")
open(f"{d}/summary.txt","w").write("\n".join(lines)+"\n")
print("\n".join(lines))
PY
}

# ---------------------------------------------------------------- suites
suite_threads() {
    local dir="$OUTDIR/threads"
    echo ">>> [threads] cube=$CUBE_BASE nl=$NODES_FIXED threads: $THREADS"
    for t in $THREADS; do run_point "$BINARY" "$CUBE_BASE" "$t" "$NODES_FIXED" "$dir" "heat3d-${t}t"; done
    aggregate_suite "$dir" "thread scaling  (${CUBE_BASE}^3, -nl ${NODES_FIXED}, ${STEPS} steps)  Execution time (s)"
}
suite_cube() {
    local dir="$OUTDIR/cube"
    echo ">>> [cube] threads=$THREAD_FIXED nl=$NODES_FIXED cubes: $CUBES"
    for c in $CUBES; do run_point "$BINARY" "$c" "$THREAD_FIXED" "$NODES_FIXED" "$dir" "heat3d-${c}cube"; done
    aggregate_suite "$dir" "cube-size sweep  (-nl ${NODES_FIXED}, ${THREAD_FIXED} threads, ${STEPS} steps)  Execution time (s)"
}
suite_nodes() {
    local dir="$OUTDIR/nodes"
    if [[ "$MODE" == "local" ]]; then echo ">>> [nodes] local mode: only -nl 1 is meaningful; running that."; NODES=1; fi
    echo ">>> [nodes] cube=$CUBE_BASE threads=$THREAD_FIXED nodes: $NODES"
    for n in $NODES; do
        if [[ "$MODE" == "cluster" && $n -gt ${#HOSTS[@]} ]]; then echo "  skip -nl $n (only ${#HOSTS[@]} hosts)"; continue; fi
        run_point "$BINARY" "$CUBE_BASE" "$THREAD_FIXED" "$n" "$dir" "heat3d-${n}nl"
    done
    aggregate_suite "$dir" "node scaling  (${CUBE_BASE}^3, ${THREAD_FIXED} threads, ${STEPS} steps)  Execution time (s)"
}
suite_llvm() {
    local dir="$OUTDIR/llvm"
    echo ">>> [llvm] cube=$CUBE_BASE threads=$THREAD_FIXED nl=$NODES_FIXED binaries: $LLVM_BINARIES"
    for pair in $LLVM_BINARIES; do
        local bin="${pair%%:*}" lbl="${pair##*:}"
        run_point "$bin" "$CUBE_BASE" "$THREAD_FIXED" "$NODES_FIXED" "$dir" "heat3d-${lbl}"
    done
    aggregate_suite "$dir" "compiler backend  (${CUBE_BASE}^3, -nl ${NODES_FIXED}, ${THREAD_FIXED} threads, ${STEPS} steps)  Execution time (s)"
}

# ---------------------------------------------------------------- main
[[ "$SUITE" == "all" ]] && SUITE="threads,cube,nodes,llvm"
IFS=',' read -ra WANT <<< "$SUITE"
for s in "${WANT[@]}"; do
    case "$s" in
        threads) suite_threads ;;
        cube)    suite_cube ;;
        nodes)   suite_nodes ;;
        llvm)    suite_llvm ;;
        *) echo "Unknown suite: $s (want threads|cube|nodes|llvm|all)" >&2; exit 1 ;;
    esac
done

echo ""
echo ">>> Done. Results under $OUTDIR/ (each suite: *.log + RESULTS.tsv + summary.txt)"
