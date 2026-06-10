#!/usr/bin/env bash
set -eo pipefail

SSH_USER="${CHAPEL_SSH_USER:-chapel}"
SSH_PORT="${CHAPEL_SSH_PORT:-22}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${SSH_PORT}"
HOSTFILE=""
SRC_DIR="$(cd "$(dirname "$0")/src" && pwd)"
BINARY_NAME="heat3d"
SWAP_NAME="heat3d-swap"
AGG_NAME="aggregate3d"
INSTALL_DIR=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] -f <hostfile>

Compile 3d.chpl and distribute the binaries to all nodes in the hostfile.
Also builds the single-locale aggregator (aggregate3d), copies it to the master,
and generates a collect+render script there (aggregate-<binary>.sh).

Options:
  -f, --hostfile FILE  File with one IP/hostname per line (required)
  -u, --user USER      SSH user (default: chapel, or \$CHAPEL_SSH_USER)
  -p, --port PORT      SSH port (default: 22, or \$CHAPEL_SSH_PORT)
  -d, --dir DIR        Remote install directory (default: /home/<user>)
  -o, --output NAME    Binary name (default: heat3d)
  -h, --help           Show this help

Examples:
  $0 -f hosts.txt
  $0 -f hosts.txt -u chapel -o heat3d
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--hostfile) HOSTFILE="$2"; shift 2 ;;
        -u|--user) SSH_USER="$2"; shift 2 ;;
        -p|--port) SSH_PORT="$2"; SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${SSH_PORT}"; shift 2 ;;
        -d|--dir)  INSTALL_DIR="$2"; shift 2 ;;
        -o|--output) BINARY_NAME="$2"; shift 2 ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$HOSTFILE" ]]; then
    echo "Error: hostfile is required (-f <file>)." >&2
    exit 1
fi

if [[ ! -f "$HOSTFILE" ]]; then
    echo "Error: hostfile '$HOSTFILE' not found." >&2
    exit 1
fi

HOSTS=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="${line// /}"
    [[ -n "$line" ]] && HOSTS+=("$line")
done < "$HOSTFILE"

if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo "Error: no hosts found in '$HOSTFILE'." >&2
    exit 1
fi

if [[ -z "$INSTALL_DIR" ]]; then
    INSTALL_DIR="/home/${SSH_USER}"
fi

# ──────────────────────────────────────────────
# 1. Compile
# ──────────────────────────────────────────────
echo ">>> Compiling ${BINARY_NAME} (ping-pong)..."
chpl --fast --main-module 3d "$SRC_DIR/3d.chpl" -o "$BINARY_NAME"
echo ">>> Compiling ${SWAP_NAME} (swap variant, for comparison)..."
chpl --fast --main-module 3d_swap "$SRC_DIR/3d_swap.chpl" -o "$SWAP_NAME"
echo ">>> Compiling ${AGG_NAME} (single-locale post-processor)..."
chpl --fast --main-module aggregate3d "$SRC_DIR/aggregate3d.chpl" "$SRC_DIR/Render3D.chpl" -o "$AGG_NAME"
echo ">>> Compilation successful"
ls -la "${BINARY_NAME}" "${BINARY_NAME}_real" \
       "${SWAP_NAME}" "${SWAP_NAME}_real" \
       "${AGG_NAME}" "${AGG_NAME}_real"

# ──────────────────────────────────────────────
# 2. Distribute
# ──────────────────────────────────────────────
echo ""
echo ">>> Distributing to ${#HOSTS[@]} node(s)..."
echo "    Remote path: $INSTALL_DIR"
echo ""

FAILED=()
for host in "${HOSTS[@]}"; do
    echo -n "    [$host] ... "

    if ! ssh $SSH_OPTS "$SSH_USER@$host" "mkdir -p '$INSTALL_DIR'" 2>/dev/null; then
        echo "FAILED (connect)"
        FAILED+=("$host")
        continue
    fi

    if ! scp -P "$SSH_PORT" -o StrictHostKeyChecking=no \
        "${BINARY_NAME}" "${BINARY_NAME}_real" \
        "${SWAP_NAME}" "${SWAP_NAME}_real" \
        "$SSH_USER@$host:$INSTALL_DIR/" 2>/dev/null; then
        echo "FAILED (scp)"
        FAILED+=("$host")
        continue
    fi

    echo "OK"
done

echo ""
echo "Succeeded: $(( ${#HOSTS[@]} - ${#FAILED[@]} )) / ${#HOSTS[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "Failed:    ${FAILED[*]}"
fi

# ──────────────────────────────────────────────
# 3. Generate run script on the first host
# ──────────────────────────────────────────────
MASTER_IP="${HOSTS[0]}"
SSH_SERVERS="${HOSTS[*]}"
NUM_LOCALES="${#HOSTS[@]}"
OTHER_HOSTS="${HOSTS[*]:1}"   # every locale except the master

# The aggregator runs single-locale on the master only; copy it there.
echo ""
echo ">>> Copying aggregator to master ($MASTER_IP)..."
if scp -P "$SSH_PORT" -o StrictHostKeyChecking=no \
    "${AGG_NAME}" "${AGG_NAME}_real" \
    "$SSH_USER@$MASTER_IP:$INSTALL_DIR/" 2>/dev/null; then
    echo "    OK"
else
    echo "    WARNING: aggregator copy failed"
fi

# Generate a -nl launcher for <binary> at <script> on the master.
gen_run_script() {
    local bin="$1" script="$2"
    ssh $SSH_OPTS "$SSH_USER@$MASTER_IP" bash -c "'cat > \"$script\"'" <<RUNSCRIPT
#!/usr/bin/env bash
export CHPL_HOME="${INSTALL_DIR}/chapel-2.7.0"
export PATH="\$CHPL_HOME/bin/linux64-x86_64:\$CHPL_HOME/util:\$PATH"
export MANPATH="\$CHPL_HOME/man:\${MANPATH:-}"

export GASNET_SSH_SERVERS="${SSH_SERVERS}"
export GASNET_MASTERIP=${MASTER_IP}
export CHPL_RT_NUM_THREADS_PER_LOCALE=\$(nproc)

cd "${INSTALL_DIR}"
./${bin} -nl ${NUM_LOCALES} "\$@"
RUNSCRIPT
    ssh $SSH_OPTS "$SSH_USER@$MASTER_IP" "chmod +x '$script'" 2>/dev/null
}

RUN_SCRIPT="${INSTALL_DIR}/run-${BINARY_NAME}.sh"
SWAP_RUN_SCRIPT="${INSTALL_DIR}/run-${SWAP_NAME}.sh"
gen_run_script "$BINARY_NAME" "$RUN_SCRIPT"
gen_run_script "$SWAP_NAME"   "$SWAP_RUN_SCRIPT"

# ──────────────────────────────────────────────
# 4. Generate the collect+aggregate script on the master
# ──────────────────────────────────────────────
# After a run, each locale has written its own slabs to <INSTALL_DIR>/frames on
# its local FS. This script pulls every other locale's frames back to the master
# (master's own are already local), then renders the movie single-locale.
# Inter-node SSH uses the internal network on the default port 22 (same as GASNet),
# NOT the dev->cluster $SSH_PORT.
AGG_SCRIPT="${INSTALL_DIR}/aggregate-${BINARY_NAME}.sh"

ssh $SSH_OPTS "$SSH_USER@$MASTER_IP" bash -c "'cat > \"$AGG_SCRIPT\"'" <<AGGSCRIPT
#!/usr/bin/env bash
export CHPL_HOME="${INSTALL_DIR}/chapel-2.7.0"
export PATH="\$CHPL_HOME/bin/linux64-x86_64:\$CHPL_HOME/util:\$PATH"
export MANPATH="\$CHPL_HOME/man:\${MANPATH:-}"

cd "${INSTALL_DIR}"
rm -rf collected && mkdir -p collected

# master's own slabs
cp -f frames/*.bin collected/ 2>/dev/null || true

# pull slabs from the other locales (filenames are unique by locale id)
for h in ${OTHER_HOSTS}; do
  echo ">>> collecting frames from \$h"
  scp -o StrictHostKeyChecking=no "${SSH_USER}@\$h:${INSTALL_DIR}/frames/*.bin" collected/ || true
done

# render single-locale; pass --nx/--ny/--nz/--numFrames to match the run
./${AGG_NAME} --render=true --dumpDir=collected "\$@"
AGGSCRIPT

ssh $SSH_OPTS "$SSH_USER@$MASTER_IP" "chmod +x '$AGG_SCRIPT'" 2>/dev/null

echo ""
echo ">>> Run scripts created on $MASTER_IP:"
echo "    $RUN_SCRIPT       (ping-pong, no swap)"
echo "    $SWAP_RUN_SCRIPT  (swap variant, for comparison)"
echo "    SSH in and run the solver(s) at the same grid size to benchmark:"
echo "    ssh ${SSH_USER}@${MASTER_IP} '$RUN_SCRIPT --nx=50 --ny=50 --nz=50 --numSteps=100'"
echo "    ssh ${SSH_USER}@${MASTER_IP} '$SWAP_RUN_SCRIPT --nx=50 --ny=50 --nz=50 --numSteps=100'"
echo ""
echo ">>> Aggregate script created on $MASTER_IP: $AGG_SCRIPT"
echo "    After the run, collect slabs from all locales and render the movie:"
echo "    ssh ${SSH_USER}@${MASTER_IP} '$AGG_SCRIPT --nx=50 --ny=50 --nz=50 --numFrames=100'"
echo "    (the resulting heat3d.mp4 lands in $INSTALL_DIR on $MASTER_IP)"
