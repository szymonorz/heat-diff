#!/usr/bin/env bash
set -euo pipefail

CHAPEL_VERSION="2.7.0"
CHAPEL_TAR="chapel-${CHAPEL_VERSION}.tar.gz"
CHAPEL_URL="https://github.com/chapel-lang/chapel/releases/download/${CHAPEL_VERSION}/${CHAPEL_TAR}"
CHAPEL_DIR="chapel-${CHAPEL_VERSION}"
ARCHIVE="chapel-${CHAPEL_VERSION}-built.tar.gz"

SSH_USER="${CHAPEL_SSH_USER:-chapel}"
SSH_PORT="${CHAPEL_SSH_PORT:-22}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${SSH_PORT}"
INSTALL_DIR=""
SKIP_BUILD=false
HOSTFILE=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] -f <hostfile>

Build Chapel locally and distribute the compiled installation to remote nodes.

Options:
  -f, --hostfile FILE  File with one IP/hostname per line (required)
  -u, --user USER      SSH user (default: chapel, or \$CHAPEL_SSH_USER)
  -p, --port PORT      SSH port (default: 22, or \$CHAPEL_SSH_PORT)
  -d, --dir DIR        Remote install directory (default: /home/<user>)
  -s, --skip-build     Skip local build, reuse existing $ARCHIVE
  -h, --help           Show this help

Hostfile format (blank lines and # comments are ignored):
  192.168.1.10
  192.168.1.11
  # this node is offline
  # 192.168.1.12

Examples:
  $0 -f hosts.txt
  $0 -f hosts.txt -u chapel -p 2222
  $0 -f hosts.txt --skip-build
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--hostfile) HOSTFILE="$2"; shift 2 ;;
        -u|--user) SSH_USER="$2"; shift 2 ;;
        -p|--port) SSH_PORT="$2"; SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${SSH_PORT}"; shift 2 ;;
        -d|--dir)  INSTALL_DIR="$2"; shift 2 ;;
        -s|--skip-build) SKIP_BUILD=true; shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  echo "Unknown argument: $1 (use -f to specify a hostfile)" >&2; exit 1 ;;
    esac
done

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

echo ">>> Loaded ${#HOSTS[@]} host(s) from $HOSTFILE"

# ──────────────────────────────────────────────
# 1. Build Chapel locally
# ──────────────────────────────────────────────
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

    if [[ -f chplconfig ]]; then
        echo ">>> Copying chplconfig into source tree..."
        cp chplconfig "$CHAPEL_DIR/chplconfig"
    fi

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
    source "$CHPL_HOME/util/setchplenv.bash"

    echo ">>> Building Chapel ${CHAPEL_VERSION} (this will take a while)..."
    make -C "$CHPL_HOME" -j"$(nproc)"

    echo ">>> Chapel build complete."
    chpl --version

    # ──────────────────────────────────────────────
    # 2. Pack the compiled directory
    # ──────────────────────────────────────────────
    echo ">>> Packing compiled Chapel into $ARCHIVE..."
    tar czf "$ARCHIVE" "$CHAPEL_DIR"
fi

ARCHIVE_SIZE=$(du -h "$ARCHIVE" | cut -f1)
echo ">>> Archive ready: $ARCHIVE ($ARCHIVE_SIZE)"

if [[ -z "$INSTALL_DIR" ]]; then
    INSTALL_DIR="/home/${SSH_USER}"
fi
REMOTE_CHPL_HOME="${INSTALL_DIR}/${CHAPEL_DIR}"

# ──────────────────────────────────────────────
# 3. Distribute to all nodes
# ──────────────────────────────────────────────
echo ""
echo ">>> Distributing to ${#HOSTS[@]} node(s)..."
echo "    Remote path: $REMOTE_CHPL_HOME"
echo "    SSH user:    $SSH_USER"
echo "    SSH port:    $SSH_PORT"
echo ""

FAILED=()
for host in "${HOSTS[@]}"; do
    echo "--- [$host] Uploading and unpacking ---"

    if ! ssh $SSH_OPTS "$SSH_USER@$host" "mkdir -p '$INSTALL_DIR'" 2>/dev/null; then
        echo "    FAILED: cannot connect to $host"
        FAILED+=("$host")
        continue
    fi

    if ! scp -P "$SSH_PORT" -o StrictHostKeyChecking=no "$ARCHIVE" "$SSH_USER@$host:$INSTALL_DIR/$ARCHIVE"; then
        echo "    FAILED: scp to $host"
        FAILED+=("$host")
        continue
    fi

    if ! ssh $SSH_OPTS "$SSH_USER@$host" bash -s <<REMOTE_SCRIPT; then
        set -e
        cd '$INSTALL_DIR'
        rm -rf '$CHAPEL_DIR'
        tar xzf '$ARCHIVE'
        rm -f '$ARCHIVE'

        # Add Chapel env to .bashrc if not already present
        MARKER="# chapel-${CHAPEL_VERSION}-env"
        if ! grep -qF "\$MARKER" ~/.bashrc 2>/dev/null; then
            cat >> ~/.bashrc <<BASHRC

\$MARKER
export CHPL_HOME="${REMOTE_CHPL_HOME}"
source "\\\$CHPL_HOME/util/setchplenv.bash"
BASHRC
        fi
REMOTE_SCRIPT
        echo "    FAILED: unpack on $host"
        FAILED+=("$host")
        continue
    fi

    echo "    OK: $host"
done

echo ""
echo "========================================"
echo "  Distribution complete"
echo "========================================"
echo "  Succeeded: $(( ${#HOSTS[@]} - ${#FAILED[@]} )) / ${#HOSTS[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "  Failed:    ${FAILED[*]}"
fi
echo ""
echo "  CHPL_HOME on all nodes: $REMOTE_CHPL_HOME"
echo "========================================"
