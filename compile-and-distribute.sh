#!/usr/bin/env bash
set -eo pipefail

SSH_USER="${CHAPEL_SSH_USER:-chapel}"
SSH_PORT="${CHAPEL_SSH_PORT:-22}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${SSH_PORT}"
HOSTFILE=""
SRC_DIR="$(cd "$(dirname "$0")/src" && pwd)"
BINARY_NAME="heat3d"
INSTALL_DIR=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] -f <hostfile>

Compile 3d.chpl and distribute the binaries to all nodes in the hostfile.

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
echo ">>> Compiling ${BINARY_NAME}..."
chpl --main-module 3d "$SRC_DIR/3d.chpl" "$SRC_DIR/Render3D.chpl" -o "$BINARY_NAME"
echo ">>> Compilation successful"
ls -la "${BINARY_NAME}" "${BINARY_NAME}_real"

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

RUN_SCRIPT="${INSTALL_DIR}/run-${BINARY_NAME}.sh"

ssh $SSH_OPTS "$SSH_USER@$MASTER_IP" bash -c "'cat > \"$RUN_SCRIPT\"'" <<RUNSCRIPT
#!/usr/bin/env bash
export CHPL_HOME="${INSTALL_DIR}/chapel-2.7.0"
export PATH="\\\$CHPL_HOME/bin/linux64-x86_64:\\\$CHPL_HOME/util:\\\$PATH"
export MANPATH="\\\$CHPL_HOME/man:\\\${MANPATH:-}"

export GASNET_SSH_SERVERS="${SSH_SERVERS}"
export GASNET_MASTERIP=${MASTER_IP}
export CHPL_RT_NUM_THREADS_PER_LOCALE=\\\$(nproc)

cd "${INSTALL_DIR}"
./${BINARY_NAME} -nl ${NUM_LOCALES} "\\\$@"
RUNSCRIPT

ssh $SSH_OPTS "$SSH_USER@$MASTER_IP" "chmod +x '$RUN_SCRIPT'" 2>/dev/null

echo ""
echo ">>> Run script created on $MASTER_IP: $RUN_SCRIPT"
echo "    SSH in and run:"
echo "    ssh ${SSH_USER}@${MASTER_IP} '$RUN_SCRIPT --nx=50 --ny=50 --nz=50'"
