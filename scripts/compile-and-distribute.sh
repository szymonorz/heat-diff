#!/usr/bin/env bash
set -eo pipefail

CHAPEL_VERSION="${CHAPEL_VERSION:-2.9.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSH_USER="${CHAPEL_SSH_USER:-chapel}"
SSH_PORT="${CHAPEL_SSH_PORT:-22}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${SSH_PORT}"
HOSTFILE=""
SRC_DIR="$(cd "$SCRIPT_DIR/../src" && pwd)"
BINARY_NAME="heat3d"
AGG_NAME="aggregate3d"
INSTALL_DIR=""
MPI_DIR=""
CONDUIT="udp"
LLVM="none"
LLVM_CONFIG=""
SKIP_COMPILE=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] -f <hostfile>

Compile 3d.chpl and distribute the binaries to all nodes in the hostfile, then generate a
conduit-aware run launcher (and a collect+render script) on this node.

Options:
  -f, --hostfile FILE  File with one IP/hostname per line, MASTER FIRST (required)
  -c, --conduit K      Conduit: udp (default) or mpi  — must match the Chapel build at -d
  -L, --llvm K         Compiler backend for the program: none (default), system or bundled.
                       Must match a backend the toolchain at -d was built with. Only the node
                       running chpl (this one) needs LLVM; the shipped binary runs without it.
      --llvm-config P  Path to llvm-config for --llvm system (e.g. /usr/bin/llvm-config-16);
                       defaults to 'llvm-config' from PATH.
  -u, --user USER      SSH user (default: chapel, or \$CHAPEL_SSH_USER)
  -p, --port PORT      SSH port (default: 22, or \$CHAPEL_SSH_PORT)
  -d, --dir DIR        Remote install dir (default: /home/<user>); CHPL_HOME=<DIR>/chapel-${CHAPEL_VERSION}
  -m, --mpi-dir DIR    MPI prefix for --conduit mpi (default: <dirname DIR>/mpi)
  -o, --output NAME    Binary name (default: heat3d)
  -V, --chapel-version V  Chapel version of the toolchain at -d (default: ${CHAPEL_VERSION}, or \$CHAPEL_VERSION)
  -s, --skip-compile   Reuse the binaries already in \$PWD; skip the chpl build, just distribute
                       and (re)generate the run/aggregate scripts
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
        -L|--llvm) LLVM="$2"; shift 2 ;;
        --llvm-config) LLVM_CONFIG="$2"; shift 2 ;;
        -u|--user) SSH_USER="$2"; shift 2 ;;
        -p|--port) SSH_PORT="$2"; SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${SSH_PORT}"; shift 2 ;;
        -d|--dir)  INSTALL_DIR="$2"; shift 2 ;;
        -m|--mpi-dir) MPI_DIR="$2"; shift 2 ;;
        -o|--output) BINARY_NAME="$2"; shift 2 ;;
        -V|--chapel-version) CHAPEL_VERSION="$2"; shift 2 ;;
        -s|--skip-compile) SKIP_COMPILE=true; shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

CHAPEL_DIR="chapel-${CHAPEL_VERSION}"

if [[ "$CONDUIT" != "udp" && "$CONDUIT" != "mpi" ]]; then
    echo "Error: --conduit must be 'udp' or 'mpi'." >&2; exit 1
fi
if [[ "$LLVM" != "none" && "$LLVM" != "system" && "$LLVM" != "bundled" ]]; then
    echo "Error: --llvm must be 'none', 'system' or 'bundled'." >&2; exit 1
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

if [[ "$SKIP_COMPILE" == false ]]; then
    CHPL_HOME_DIR="${INSTALL_DIR}/${CHAPEL_DIR}"
    export CHPL_LLVM="$LLVM"
    if [[ "$LLVM" == "system" ]]; then
        [[ -z "$LLVM_CONFIG" ]] && LLVM_CONFIG="$(command -v llvm-config || true)"
        if [[ -z "$LLVM_CONFIG" || ! -x "$LLVM_CONFIG" ]]; then
            echo "Error: --llvm system but no usable llvm-config here. Install LLVM dev packages or pass --llvm-config PATH." >&2
            exit 1
        fi
        export CHPL_LLVM_CONFIG="$LLVM_CONFIG"
    fi
    if [[ -f "$CHPL_HOME_DIR/util/setchplenv.bash" ]]; then
        export CHPL_HOME="$CHPL_HOME_DIR"
        [[ "$CONDUIT" == "mpi" ]] && export PATH="$MPI_DIR/bin:$PATH"
        source "$CHPL_HOME/util/setchplenv.bash" >/dev/null 2>&1
    elif ! command -v chpl >/dev/null 2>&1; then
        echo "Error: chpl not found and $CHPL_HOME_DIR missing. Build/distribute Chapel first." >&2
        exit 1
    fi

    echo ">>> Conduit: $CONDUIT   LLVM: $LLVM   CHPL_HOME=${CHPL_HOME:-<from PATH>}"
    echo ">>> Compiling ${BINARY_NAME} (operator zamiany <=>)..."
    chpl --fast --main-module 3d "$SRC_DIR/3d.chpl" -o "$BINARY_NAME"
    echo ">>> Compiling ${AGG_NAME} (single-locale post-processor)..."
    chpl --fast --main-module aggregate3d "$SRC_DIR/aggregate3d.chpl" "$SRC_DIR/ImageUtils.chpl" -o "$AGG_NAME"
    echo ">>> Compilation successful"
    ls -la "${BINARY_NAME}" "${BINARY_NAME}_real" "${AGG_NAME}" "${AGG_NAME}_real"
else
    echo ">>> Conduit: $CONDUIT   (--skip-compile: reusing existing binaries in $PWD)"
    MISSING=()
    for b in "${BINARY_NAME}" "${BINARY_NAME}_real" "${AGG_NAME}" "${AGG_NAME}_real"; do
        [[ -f "$b" ]] || MISSING+=("$b")
    done
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        echo "Error: --skip-compile but these binaries are missing in $PWD: ${MISSING[*]}" >&2
        echo "  Run once without --skip-compile to build them first." >&2
        exit 1
    fi
    echo ">>> Reusing binaries: ${BINARY_NAME}, ${AGG_NAME}"
fi

echo ""
echo ">>> Distributing to ${#HOSTS[@]} node(s) at $INSTALL_DIR ..."
FAILED=()
for host in "${HOSTS[@]}"; do
    echo -n "    [$host] ... "
    if ! ssh $SSH_OPTS "$SSH_USER@$host" "mkdir -p '$INSTALL_DIR'" 2>/dev/null; then
        echo "FAILED (connect)"; FAILED+=("$host"); continue
    fi
    if ! scp -P "$SSH_PORT" -o StrictHostKeyChecking=no \
        "${BINARY_NAME}" "${BINARY_NAME}_real" \
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

MASTER_IP="${HOSTS[0]}"
SSH_SERVERS="${HOSTS[*]}"
HOSTS_COMMA="$(IFS=,; echo "${HOSTS[*]}")"
NUM_LOCALES="${#HOSTS[@]}"
OTHER_HOSTS="${HOSTS[*]:1}"

RUN_ENV="${INSTALL_DIR}/run-env.sh"
cat > "$RUN_ENV" <<RUNENV
export CHPL_HOME="${INSTALL_DIR}/${CHAPEL_DIR}"
export MANPATH="\$CHPL_HOME/man:\${MANPATH:-}"
RUN_CONDUIT="${CONDUIT}"
RUN_ALL_HOSTS="${SSH_SERVERS}"
RUN_IFACE_WRAP="${INSTALL_DIR}/mpi-iface-wrap.sh"
RUN_MPI_DIR="${MPI_DIR}"

if [ "\$RUN_CONDUIT" = "mpi" ]; then
    export PATH="\$RUN_MPI_DIR/bin:\$CHPL_HOME/bin/linux64-x86_64:\$CHPL_HOME/util:\$PATH"
else
    export PATH="\$CHPL_HOME/bin/linux64-x86_64:\$CHPL_HOME/util:\$PATH"
fi

set_run_env() {
    local nl="\${1:?usage: set_run_env <numLocales>}"
    local all=(\$RUN_ALL_HOSTS)
    local sub=("\${all[@]:0:\$nl}")
    local comma; comma="\$(IFS=,; echo "\${sub[*]}")"
    if [ "\$RUN_CONDUIT" = "mpi" ]; then
        export CHPL_MPI_HOSTS="\$comma"
        export MPIRUN_CMD="mpirun -n %N -hosts \$comma \$RUN_IFACE_WRAP %C"
        unset GASNET_SSH_SERVERS GASNET_MASTERIP 2>/dev/null || true
    else
        export GASNET_SSH_SERVERS="\${sub[*]}"
        export GASNET_MASTERIP="\${sub[0]}"
        unset MPIRUN_CMD CHPL_MPI_HOSTS 2>/dev/null || true
    fi
    export CHPL_RT_NUM_THREADS_PER_LOCALE="\${CHPL_RT_NUM_THREADS_PER_LOCALE:-\$(nproc)}"
}
RUNENV
chmod +x "$RUN_ENV"
if [[ "$CONDUIT" == "mpi" ]]; then
    cp -f "$SCRIPT_DIR/mpi-iface-wrap.sh" "$INSTALL_DIR/mpi-iface-wrap.sh" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/mpi-iface-wrap.sh" 2>/dev/null || true
fi
echo ">>> Shared launcher env: $RUN_ENV"

echo ""
echo ">>> Copying aggregator to master ($MASTER_IP)..."
scp -P "$SSH_PORT" -o StrictHostKeyChecking=no "${AGG_NAME}" "${AGG_NAME}_real" \
    "$SSH_USER@$MASTER_IP:$INSTALL_DIR/" 2>/dev/null && echo "    OK" || echo "    WARNING: aggregator copy failed"

gen_run_script() {
    local bin="$1" script="$2"
    cat > "$script" <<RUNSCRIPT
#!/usr/bin/env bash
source "${INSTALL_DIR}/run-env.sh"
set_run_env ${NUM_LOCALES}
cd "${INSTALL_DIR}"
LOG="\${LOG:-${INSTALL_DIR}/logs/${bin}-\$(date +%Y%m%d-%H%M%S).log}"
mkdir -p "\$(dirname "\$LOG")"
echo ">>> ${bin} -nl ${NUM_LOCALES} \$* (threadsPerLocale=\$CHPL_RT_NUM_THREADS_PER_LOCALE) | tee \$LOG"
set -o pipefail
{
  echo "[cfg] threadsPerLocale(requested)=\$CHPL_RT_NUM_THREADS_PER_LOCALE numLocales=${NUM_LOCALES}"
  ./${bin} -nl ${NUM_LOCALES} "\$@" 2>&1
} | tee "\$LOG"
RUNSCRIPT
    chmod +x "$script"
}

RUN_SCRIPT="${INSTALL_DIR}/run-${BINARY_NAME}.sh"
gen_run_script "$BINARY_NAME" "$RUN_SCRIPT"

AGG_SCRIPT="${INSTALL_DIR}/aggregate-${BINARY_NAME}.sh"
cat > "$AGG_SCRIPT" <<AGGSCRIPT
#!/usr/bin/env bash
source "${INSTALL_DIR}/run-env.sh"
set_run_env 1

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
echo "    e.g. $RUN_SCRIPT --nx=100 --ny=100 --nz=100 --numSteps=100"
echo ">>> Aggregate script: $AGG_SCRIPT"
