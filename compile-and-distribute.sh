#!/usr/bin/env bash
set -eo pipefail

CHAPEL_VERSION="${CHAPEL_VERSION:-2.9.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSH_USER="${CHAPEL_SSH_USER:-chapel}"
SSH_PORT="${CHAPEL_SSH_PORT:-22}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${SSH_PORT}"
HOSTFILE=""
SRC_DIR="$(cd "$(dirname "$0")/src" && pwd)"
BINARY_NAME="heat3d"
SWAP_NAME="heat3d-swap"
AGG_NAME="aggregate3d"
INSTALL_DIR=""
MPI_DIR=""
CONDUIT="udp"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] -f <hostfile>

Compile 3d.chpl and distribute the binaries to all nodes in the hostfile, then generate a
conduit-aware run launcher (and a collect+render script) on this node.

Options:
  -f, --hostfile FILE  File with one IP/hostname per line, MASTER FIRST (required)
  -c, --conduit K      Conduit: udp (default) or mpi  — must match the Chapel build at -d
  -u, --user USER      SSH user (default: chapel, or \$CHAPEL_SSH_USER)
  -p, --port PORT      SSH port (default: 22, or \$CHAPEL_SSH_PORT)
  -d, --dir DIR        Remote install dir (default: /home/<user>); CHPL_HOME=<DIR>/chapel-${CHAPEL_VERSION}
  -m, --mpi-dir DIR    MPI prefix for --conduit mpi (default: <dirname DIR>/mpi)
  -o, --output NAME    Binary name (default: heat3d)
  -V, --chapel-version V  Chapel version of the toolchain at -d (default: ${CHAPEL_VERSION}, or \$CHAPEL_VERSION)
  -h, --help           Show this help

Examples:
  $0 -f hosts.txt
  $0 --conduit mpi -f hosts-both.txt -d /home/chapel/workspace/chapel-mpi
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--hostfile) HOSTFILE="$2"; shift 2 ;;
        -c|--conduit)  CONDUIT="$2"; shift 2 ;;
        -u|--user) SSH_USER="$2"; shift 2 ;;
        -p|--port) SSH_PORT="$2"; SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${SSH_PORT}"; shift 2 ;;
        -d|--dir)  INSTALL_DIR="$2"; shift 2 ;;
        -m|--mpi-dir) MPI_DIR="$2"; shift 2 ;;
        -o|--output) BINARY_NAME="$2"; shift 2 ;;
        -V|--chapel-version) CHAPEL_VERSION="$2"; shift 2 ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Version-derived path (computed after parsing so --chapel-version takes effect)
CHAPEL_DIR="chapel-${CHAPEL_VERSION}"

if [[ "$CONDUIT" != "udp" && "$CONDUIT" != "mpi" ]]; then
    echo "Error: --conduit must be 'udp' or 'mpi'." >&2; exit 1
fi
if [[ -z "$HOSTFILE" || ! -f "$HOSTFILE" ]]; then
    echo "Error: valid hostfile required (-f <file>)." >&2; exit 1
fi

HOSTS=()
while IFS= read -r line; do
    line="${line%%#*}"; line="${line// /}"
    [[ -n "$line" ]] && HOSTS+=("$line")
done < "$HOSTFILE"
[[ ${#HOSTS[@]} -gt 0 ]] || { echo "Error: no hosts in '$HOSTFILE'." >&2; exit 1; }

if [[ -z "$INSTALL_DIR" ]]; then INSTALL_DIR="/home/${SSH_USER}"; fi
if [[ -z "$MPI_DIR" ]]; then MPI_DIR="$(dirname "$INSTALL_DIR")/mpi"; fi

# ──────────────────────────────────────────────
# 0. Activate the matching Chapel toolchain
# ──────────────────────────────────────────────
CHPL_HOME_DIR="${INSTALL_DIR}/${CHAPEL_DIR}"
if [[ -f "$CHPL_HOME_DIR/util/setchplenv.bash" ]]; then
    export CHPL_HOME="$CHPL_HOME_DIR"
    [[ "$CONDUIT" == "mpi" ]] && export PATH="$MPI_DIR/bin:$PATH"
    source "$CHPL_HOME/util/setchplenv.bash" >/dev/null 2>&1
elif ! command -v chpl >/dev/null 2>&1; then
    echo "Error: chpl not found and $CHPL_HOME_DIR missing. Build/distribute Chapel first." >&2
    exit 1
fi

# ──────────────────────────────────────────────
# 1. Compile
# ──────────────────────────────────────────────
# CHPL_TARGET_CPU is not set here: chpl reads it from $CHPL_HOME/chplconfig (baked in at build
# time by distribute-chapel.sh), so --fast/--specialize tunes to whatever the runtime was built
# for. Setting it here instead would risk a "runtime not built for this configuration" error.
echo ">>> Conduit: $CONDUIT   CHPL_HOME=${CHPL_HOME:-<from PATH>}"
echo ">>> Compiling ${BINARY_NAME} (ping-pong)..."
chpl --fast --main-module 3d "$SRC_DIR/3d.chpl" "$SRC_DIR/Diagnostics.chpl" -o "$BINARY_NAME"
echo ">>> Compiling ${SWAP_NAME} (swap variant)..."
chpl --fast --main-module 3d_swap "$SRC_DIR/3d_swap.chpl" -o "$SWAP_NAME"
echo ">>> Compiling ${AGG_NAME} (single-locale post-processor)..."
chpl --fast --main-module aggregate3d "$SRC_DIR/aggregate3d.chpl" "$SRC_DIR/ImageUtils.chpl" -o "$AGG_NAME"
echo ">>> Compilation successful"
ls -la "${BINARY_NAME}" "${BINARY_NAME}_real" "${SWAP_NAME}" "${SWAP_NAME}_real" "${AGG_NAME}" "${AGG_NAME}_real"

# ──────────────────────────────────────────────
# 2. Distribute binaries (+ iface wrapper for mpi)
# ──────────────────────────────────────────────
echo ""
echo ">>> Distributing to ${#HOSTS[@]} node(s) at $INSTALL_DIR ..."
FAILED=()
for host in "${HOSTS[@]}"; do
    echo -n "    [$host] ... "
    if ! ssh $SSH_OPTS "$SSH_USER@$host" "mkdir -p '$INSTALL_DIR'" 2>/dev/null; then
        echo "FAILED (connect)"; FAILED+=("$host"); continue
    fi
    if ! scp -P "$SSH_PORT" -o StrictHostKeyChecking=no \
        "${BINARY_NAME}" "${BINARY_NAME}_real" "${SWAP_NAME}" "${SWAP_NAME}_real" \
        "$SSH_USER@$host:$INSTALL_DIR/" 2>/dev/null; then
        echo "FAILED (scp)"; FAILED+=("$host"); continue
    fi
    if [[ "$CONDUIT" == "mpi" ]]; then
        scp -P "$SSH_PORT" -o StrictHostKeyChecking=no "$SCRIPT_DIR/mpi-iface-wrap.sh" \
            "$SSH_USER@$host:$INSTALL_DIR/" 2>/dev/null || true
        ssh $SSH_OPTS "$SSH_USER@$host" "chmod +x '$INSTALL_DIR/mpi-iface-wrap.sh'" 2>/dev/null || true
    fi
    echo "OK"
done
echo ""
echo "Succeeded: $(( ${#HOSTS[@]} - ${#FAILED[@]} )) / ${#HOSTS[@]}"
[[ ${#FAILED[@]} -gt 0 ]] && echo "Failed:    ${FAILED[*]}"

# ──────────────────────────────────────────────
# 3. Generate the run launcher(s) — conduit-aware
# ──────────────────────────────────────────────
MASTER_IP="${HOSTS[0]}"
SSH_SERVERS="${HOSTS[*]}"                       # space-separated (udp)
HOSTS_COMMA="$(IFS=,; echo "${HOSTS[*]}")"      # comma-separated (mpi -hosts)
NUM_LOCALES="${#HOSTS[@]}"
OTHER_HOSTS="${HOSTS[*]:1}"

# Copy the single-locale aggregator to the master (it runs -nl 1 there).
echo ""
echo ">>> Copying aggregator to master ($MASTER_IP)..."
scp -P "$SSH_PORT" -o StrictHostKeyChecking=no "${AGG_NAME}" "${AGG_NAME}_real" \
    "$SSH_USER@$MASTER_IP:$INSTALL_DIR/" 2>/dev/null && echo "    OK" || echo "    WARNING: aggregator copy failed"

gen_run_script() {
    local bin="$1" script="$2"
    if [[ "$CONDUIT" == "mpi" ]]; then
        cat > "$script" <<RUNSCRIPT
#!/usr/bin/env bash
# mpi-conduit launcher (GASNet over MPICH/TCP). hydra round-robins locales over the hosts.
export CHPL_HOME="${INSTALL_DIR}/${CHAPEL_DIR}"
export PATH="${MPI_DIR}/bin:\$CHPL_HOME/bin/linux64-x86_64:\$CHPL_HOME/util:\$PATH"
export MANPATH="\$CHPL_HOME/man:\${MANPATH:-}"

# host list for the per-rank interface wrapper (fixes ch3:sock business-card on multi-homed nodes)
export CHPL_MPI_HOSTS="${HOSTS_COMMA}"
export MPIRUN_CMD="mpirun -n %N -hosts ${HOSTS_COMMA} ${INSTALL_DIR}/mpi-iface-wrap.sh %C"
export CHPL_RT_NUM_THREADS_PER_LOCALE=\${CHPL_RT_NUM_THREADS_PER_LOCALE:-\$(nproc)}

cd "${INSTALL_DIR}"
./${bin} -nl ${NUM_LOCALES} "\$@"
RUNSCRIPT
    else
        cat > "$script" <<RUNSCRIPT
#!/usr/bin/env bash
# udp-conduit launcher (GASNet AMUDP over ssh-spawned workers).
export CHPL_HOME="${INSTALL_DIR}/${CHAPEL_DIR}"
export PATH="\$CHPL_HOME/bin/linux64-x86_64:\$CHPL_HOME/util:\$PATH"
export MANPATH="\$CHPL_HOME/man:\${MANPATH:-}"

export GASNET_SSH_SERVERS="${SSH_SERVERS}"
export GASNET_MASTERIP=${MASTER_IP}
export CHPL_RT_NUM_THREADS_PER_LOCALE=\${CHPL_RT_NUM_THREADS_PER_LOCALE:-\$(nproc)}

cd "${INSTALL_DIR}"
./${bin} -nl ${NUM_LOCALES} "\$@"
RUNSCRIPT
    fi
    chmod +x "$script"
}

RUN_SCRIPT="${INSTALL_DIR}/run-${BINARY_NAME}.sh"
SWAP_RUN_SCRIPT="${INSTALL_DIR}/run-${SWAP_NAME}.sh"
gen_run_script "$BINARY_NAME" "$RUN_SCRIPT"
gen_run_script "$SWAP_NAME"   "$SWAP_RUN_SCRIPT"

# ──────────────────────────────────────────────
# 4. Generate the collect+aggregate script on the master
# ──────────────────────────────────────────────
AGG_SCRIPT="${INSTALL_DIR}/aggregate-${BINARY_NAME}.sh"
cat > "$AGG_SCRIPT" <<AGGSCRIPT
#!/usr/bin/env bash
export CHPL_HOME="${INSTALL_DIR}/${CHAPEL_DIR}"
export PATH="\$CHPL_HOME/bin/linux64-x86_64:\$CHPL_HOME/util:\$PATH"
export MANPATH="\$CHPL_HOME/man:\${MANPATH:-}"

cd "${INSTALL_DIR}"
rm -rf collected && mkdir -p collected
cp -f frames/*.bin collected/ 2>/dev/null || true
for h in ${OTHER_HOSTS}; do
  echo ">>> collecting frames from \$h"
  scp -o StrictHostKeyChecking=no "${SSH_USER}@\$h:${INSTALL_DIR}/frames/*.bin" collected/ || true
done
./${AGG_NAME} --render=true --dumpDir=collected "\$@"
AGGSCRIPT
chmod +x "$AGG_SCRIPT"

echo ""
echo ">>> Run scripts created locally ($CONDUIT conduit):"
echo "    $RUN_SCRIPT"
echo "    $SWAP_RUN_SCRIPT"
echo "    e.g. $RUN_SCRIPT --nx=100 --ny=100 --nz=100 --numSteps=100"
echo ">>> Aggregate script: $AGG_SCRIPT"
