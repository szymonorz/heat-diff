#!/usr/bin/env bash
set -euo pipefail

CHAPEL_VERSION="${CHAPEL_VERSION:-2.9.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSH_USER="${CHAPEL_SSH_USER:-chapel}"
SSH_PORT="${CHAPEL_SSH_PORT:-22}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${SSH_PORT}"
INSTALL_DIR=""
MPI_DIR=""
CONDUIT="udp"
TARGET_CPU="native"
LLVM="none"
LLVM_CONFIG=""
SKIP_BUILD=false
HOSTFILE=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] -f <hostfile>

Build Chapel locally and distribute the compiled installation to remote nodes.
The communication conduit is selected with --conduit (default: udp).

  udp : GASNet AMUDP. No extra deps. Fast on a clean LAN, but aborts with ECONGESTION
        under packet loss / many-to-one incast at scale.
  mpi : GASNet mpi-conduit over MPICH/TCP. Survives loss/incast (TCP flow control).
        Auto-builds MPICH from source into --mpi-dir and ships it to every node.

Options:
  -f, --hostfile FILE  File with one IP/hostname per line (required)
  -c, --conduit K      Conduit: udp (default) or mpi
  -L, --llvm K         Compiler backend baked into the toolchain: none (default, C backend),
                       system (use an installed LLVM via llvm-config; version must be in Chapel's
                       supported range), or bundled (build LLVM from source; large + slow).
                       Only the BUILD node needs LLVM: it is a compile-time dependency, so the
                       shipped program binaries do NOT link libLLVM and run on nodes without it.
      --llvm-config P  Path to llvm-config for --llvm system (e.g. /usr/bin/llvm-config-16);
                       defaults to 'llvm-config' from PATH.
  -u, --user USER      SSH user (default: chapel, or \$CHAPEL_SSH_USER)
  -p, --port PORT      SSH port (default: 22, or \$CHAPEL_SSH_PORT)
  -d, --dir DIR        Remote install dir (default: /home/<user>); CHPL_HOME=<DIR>/chapel-${CHAPEL_VERSION}
                       Use a distinct dir per conduit (e.g. .../chapel and .../chapel-mpi).
  -m, --mpi-dir DIR    MPI install prefix for --conduit mpi (default: <dirname DIR>/mpi)
  -t, --target-cpu C   CHPL_TARGET_CPU baked into the shipped runtime (default: native).
                       'native' tunes for the BUILD host's CPU — safe on a CPU-homogeneous
                       cluster. Use 'unknown' for generic/portable code on a mixed-CPU cluster.
  -V, --chapel-version V  Chapel version to download/build (default: ${CHAPEL_VERSION}, or \$CHAPEL_VERSION)
  -s, --skip-build     Skip local Chapel build, reuse existing chapel-${CHAPEL_VERSION}-built.tar.gz
  -h, --help           Show this help

NOTE (heterogeneous clusters): build on the node with the OLDEST glibc; its binaries run on
newer-glibc nodes, not vice-versa. Run this script there.

Examples:
  $0 -f hosts.txt                                   # udp, default
  $0 --conduit mpi -f hosts.txt -d /home/chapel/workspace/chapel-mpi
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
        -t|--target-cpu) TARGET_CPU="$2"; shift 2 ;;
        -V|--chapel-version) CHAPEL_VERSION="$2"; shift 2 ;;
        -s|--skip-build) SKIP_BUILD=true; shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  echo "Unknown argument: $1 (use -f to specify a hostfile)" >&2; exit 1 ;;
    esac
done

CHAPEL_TAR="chapel-${CHAPEL_VERSION}.tar.gz"
CHAPEL_URL="https://github.com/chapel-lang/chapel/releases/download/${CHAPEL_VERSION}/${CHAPEL_TAR}"
CHAPEL_DIR="chapel-${CHAPEL_VERSION}"
ARCHIVE="chapel-${CHAPEL_VERSION}-built.tar.gz"

if [[ "$CONDUIT" != "udp" && "$CONDUIT" != "mpi" ]]; then
    echo "Error: --conduit must be 'udp' or 'mpi' (got '$CONDUIT')." >&2
    exit 1
fi
if [[ "$LLVM" != "none" && "$LLVM" != "system" && "$LLVM" != "bundled" ]]; then
    echo "Error: --llvm must be 'none', 'system' or 'bundled' (got '$LLVM')." >&2
    exit 1
fi

if [[ -z "$HOSTFILE" ]]; then
    echo "Error: hostfile is required (-f <file>)." >&2
    echo "Run '$0 --help' for usage." >&2
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

echo ">>> Conduit: $CONDUIT"
echo ">>> Loaded ${#HOSTS[@]} host(s) from $HOSTFILE"

if [[ -z "$INSTALL_DIR" ]]; then
    INSTALL_DIR="/home/${SSH_USER}"
fi
if [[ -z "$MPI_DIR" ]]; then
    MPI_DIR="$(dirname "$INSTALL_DIR")/mpi"
fi

if [[ "$CONDUIT" == "mpi" ]]; then
    echo ">>> MPI prefix: $MPI_DIR"
    bash "$SCRIPT_DIR/build-mpi.sh" --prefix "$MPI_DIR"
    export PATH="$MPI_DIR/bin:$PATH"
    export MPI_CC="$MPI_DIR/bin/mpicc"
fi

if [[ "$SKIP_BUILD" == true ]]; then
    if [[ ! -f "$ARCHIVE" ]]; then
        echo "Error: --skip-build specified but $ARCHIVE not found." >&2
        exit 1
    fi
    echo ">>> Skipping build, reusing existing $ARCHIVE"
    LOCAL_CHPL_HOME="$(pwd)/${CHAPEL_DIR}"
else
    if [[ -f "$CHAPEL_TAR" ]] && ! gzip -t "$CHAPEL_TAR" 2>/dev/null; then
        echo ">>> Existing source tarball is corrupted, removing..."
        rm -f "$CHAPEL_TAR"
    fi

    if [[ ! -f "$CHAPEL_TAR" ]]; then
        echo ">>> Downloading Chapel ${CHAPEL_VERSION}..."
        wget -q --show-progress "$CHAPEL_URL"
    fi

    if [[ ! -d "$CHAPEL_DIR" ]]; then
        echo ">>> Extracting Chapel source..."
        tar xzf "$CHAPEL_TAR"
    fi

    LOCAL_CHPL_HOME="$(cd "$CHAPEL_DIR" && pwd)"

    if [[ "$LLVM" == "system" ]]; then
        [[ -z "$LLVM_CONFIG" ]] && LLVM_CONFIG="$(command -v llvm-config || true)"
        if [[ -z "$LLVM_CONFIG" || ! -x "$LLVM_CONFIG" ]]; then
            echo "Error: --llvm system but no usable llvm-config on this build node. Install the LLVM dev packages or pass --llvm-config PATH." >&2
            exit 1
        fi
        export CHPL_LLVM_CONFIG="$LLVM_CONFIG"
        echo ">>> Using system LLVM: $("$LLVM_CONFIG" --version) ($LLVM_CONFIG)"
    fi

    echo ">>> Writing chplconfig (CHPL_COMM_SUBSTRATE=$CONDUIT, CHPL_LLVM=$LLVM, CHPL_TARGET_CPU=$TARGET_CPU)..."
    cat > "$CHAPEL_DIR/chplconfig" <<CHPLCFG
CHPL_COMM=gasnet
CHPL_COMM_SUBSTRATE=$CONDUIT
CHPL_LLVM=$LLVM
CHPL_TARGET_CPU=$TARGET_CPU
CHPLCFG

    CMAKE_MIN="3.20.0"
    CMAKE_CUR=$(cmake --version 2>/dev/null | head -1 | awk '{print $3}')
    if [[ -z "$CMAKE_CUR" ]] || [[ "$(printf '%s\n' "$CMAKE_MIN" "$CMAKE_CUR" | sort -V | head -1)" != "$CMAKE_MIN" ]]; then
        echo ">>> System cmake ($CMAKE_CUR) is too old, installing newer cmake via pip..."
        pip3 install cmake
        export PATH="$HOME/.local/bin:$PATH"
        echo ">>> cmake version: $(cmake --version | head -1)"
    fi

    export CHPL_HOME="$LOCAL_CHPL_HOME"
    export MANPATH="${MANPATH:-}"
    export CHPL_LLVM="$LLVM"
    source "$CHPL_HOME/util/setchplenv.bash"

    echo ">>> Building Chapel ${CHAPEL_VERSION} ($CONDUIT conduit, LLVM=$LLVM; this will take a while)..."
    make -C "$CHPL_HOME" -j"$(nproc)"

    echo ">>> Chapel build complete."
    chpl --version

    echo ">>> Packing compiled Chapel into $ARCHIVE..."
    tar czf "$ARCHIVE" "$CHAPEL_DIR"
fi

ARCHIVE_SIZE=$(du -h "$ARCHIVE" | cut -f1)
echo ">>> Archive ready: $ARCHIVE ($ARCHIVE_SIZE)"

REMOTE_CHPL_HOME="${INSTALL_DIR}/${CHAPEL_DIR}"
MPI_PARENT="$(dirname "$MPI_DIR")"
MPI_BASE="$(basename "$MPI_DIR")"

echo ""
echo ">>> Distributing to ${#HOSTS[@]} node(s)..."
echo "    Chapel path: $REMOTE_CHPL_HOME"
[[ "$CONDUIT" == "mpi" ]] && echo "    MPI path:    $MPI_DIR"
echo "    SSH user:    $SSH_USER    port: $SSH_PORT"
echo ""

FAILED=()
for host in "${HOSTS[@]}"; do
    echo "--- [$host] ---"

    if ! ssh $SSH_OPTS "$SSH_USER@$host" "mkdir -p '$INSTALL_DIR' '$MPI_PARENT'" 2>/dev/null; then
        echo "    FAILED: cannot connect to $host"
        FAILED+=("$host"); continue
    fi

    if [[ "$CONDUIT" == "mpi" ]]; then
        if ssh $SSH_OPTS "$SSH_USER@$host" "[ -x '$MPI_DIR/bin/mpicc' ]" 2>/dev/null; then
            echo "    MPI: already present, skipping"
        else
            echo "    MPI: shipping $MPI_BASE ..."
            if ! tar czf - -C "$MPI_PARENT" "$MPI_BASE" | ssh $SSH_OPTS "$SSH_USER@$host" "tar xzf - -C '$MPI_PARENT'"; then
                echo "    FAILED: MPI ship to $host"; FAILED+=("$host"); continue
            fi
        fi
    fi

    if ! scp -P "$SSH_PORT" -o StrictHostKeyChecking=no "$ARCHIVE" "$SSH_USER@$host:$INSTALL_DIR/$ARCHIVE"; then
        echo "    FAILED: scp to $host"; FAILED+=("$host"); continue
    fi

    if ! ssh $SSH_OPTS "$SSH_USER@$host" \
            CONDUIT="$CONDUIT" REMOTE_CHPL_HOME="$REMOTE_CHPL_HOME" \
            INSTALL_DIR="$INSTALL_DIR" CHAPEL_DIR="$CHAPEL_DIR" \
            ARCHIVE="$ARCHIVE" MPI_DIR="$MPI_DIR" bash -s <<'REMOTE_SCRIPT'; then
        set -e
        cd "$INSTALL_DIR"
        rm -rf "$CHAPEL_DIR"
        tar xzf "$ARCHIVE"
        rm -f "$ARCHIVE"

        MARKER="# chapel-env ($REMOTE_CHPL_HOME)"
        if ! grep -qF "$MARKER" ~/.bashrc 2>/dev/null; then
            {
                echo ""
                echo "$MARKER"
                if [ "$CONDUIT" = "mpi" ]; then
                    echo "export PATH=\"$MPI_DIR/bin:\$PATH\""
                fi
                echo "export CHPL_HOME=\"$REMOTE_CHPL_HOME\""
                echo "source \"\$CHPL_HOME/util/setchplenv.bash\" >/dev/null 2>&1"
            } >> ~/.bashrc
        fi
REMOTE_SCRIPT
        echo "    FAILED: unpack on $host"; FAILED+=("$host"); continue
    fi

    echo "    OK: $host"
done

echo ""
echo "========================================"
echo "  Distribution complete ($CONDUIT, LLVM=$LLVM)"
echo "========================================"
echo "  Succeeded: $(( ${#HOSTS[@]} - ${#FAILED[@]} )) / ${#HOSTS[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "  Failed:    ${FAILED[*]}"
fi
echo ""
echo "  CHPL_HOME on all nodes: $REMOTE_CHPL_HOME"
[[ "$CONDUIT" == "mpi" ]] && echo "  MPI on all nodes:       $MPI_DIR"
echo "  Next: compile-and-distribute.sh --conduit $CONDUIT -f <hostfile> -d $INSTALL_DIR"
echo "========================================"
