#!/usr/bin/env bash
#
# Build Chapel locally on THIS node only (no distribution). For build+distribute across a
# cluster use distribute-chapel.sh instead.
#
# Portable: does NOT assume a package manager. It verifies the required build tools are present
# and tells you the install command for your distro if any are missing.
#
set -eo pipefail

CHAPEL_VERSION="2.7.0"
CHAPEL_TAR="chapel-${CHAPEL_VERSION}.tar.gz"
CHAPEL_URL="https://github.com/chapel-lang/chapel/releases/download/${CHAPEL_VERSION}/${CHAPEL_TAR}"
INSTALL_DIR="$PWD/chapel-${CHAPEL_VERSION}"
CONDUIT="udp"
MPI_DIR=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $0 [--conduit udp|mpi] [--mpi-dir DIR]

Build Chapel ${CHAPEL_VERSION} in \$PWD/chapel-${CHAPEL_VERSION} (CHPL_LLVM=none).

Options:
  -c, --conduit K   Conduit: udp (default) or mpi
  -m, --mpi-dir DIR MPI prefix for --conduit mpi (default: \$PWD/mpi); MPICH is auto-built there
  -h, --help        Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--conduit) CONDUIT="$2"; shift 2 ;;
        -m|--mpi-dir) MPI_DIR="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done
[[ "$CONDUIT" == "udp" || "$CONDUIT" == "mpi" ]] || { echo "Error: --conduit must be udp or mpi." >&2; exit 1; }
[[ -z "$MPI_DIR" ]] && MPI_DIR="$PWD/mpi"

# ──────────────────────────────────────────────
# 1. Verify build dependencies (portable; no auto-install without root)
# ──────────────────────────────────────────────
echo ">>> Checking build dependencies..."
MISSING=()
for c in gcc g++ make m4 perl python3 cmake wget gzip; do
    command -v "$c" >/dev/null 2>&1 || MISSING+=("$c")
done
[[ -f /usr/include/gmp.h ]] || MISSING+=("gmp-dev(gmp.h)")
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "Error: missing build dependencies: ${MISSING[*]}" >&2
    echo "  Debian/Ubuntu: sudo apt-get install gcc g++ make m4 perl python3 python3-dev cmake wget libgmp-dev" >&2
    echo "  Fedora:        sudo dnf install gcc gcc-c++ make m4 perl python3 python3-devel cmake wget gmp-devel" >&2
    echo "  Void:          sudo xbps-install -S gcc make m4 perl python3 cmake wget gmp-devel" >&2
    exit 1
fi

CMAKE_MIN="3.20.0"
CMAKE_CUR=$(cmake --version 2>/dev/null | head -1 | awk '{print $3}')
if [[ -z "$CMAKE_CUR" ]] || [[ "$(printf '%s\n' "$CMAKE_MIN" "$CMAKE_CUR" | sort -V | head -1)" != "$CMAKE_MIN" ]]; then
    echo ">>> System cmake ($CMAKE_CUR) too old; installing newer cmake via pip..."
    pip3 install --user cmake
    export PATH="$HOME/.local/bin:$PATH"
fi

# ──────────────────────────────────────────────
# 2. (mpi) Build MPICH from source
# ──────────────────────────────────────────────
if [[ "$CONDUIT" == "mpi" ]]; then
    bash "$SCRIPT_DIR/build-mpi.sh" --prefix "$MPI_DIR"
    export PATH="$MPI_DIR/bin:$PATH"
    export MPI_CC="$MPI_DIR/bin/mpicc"
fi

# ──────────────────────────────────────────────
# 3. Download + extract Chapel
# ──────────────────────────────────────────────
if [[ -f "$CHAPEL_TAR" ]] && ! gzip -t "$CHAPEL_TAR" 2>/dev/null; then
    echo ">>> Existing tarball corrupt, removing..."; rm -f "$CHAPEL_TAR"
fi
[[ -f "$CHAPEL_TAR" ]] || { echo ">>> Downloading Chapel ${CHAPEL_VERSION}..."; wget "$CHAPEL_URL"; }
[[ -d "$INSTALL_DIR" ]] || { echo ">>> Extracting Chapel..."; tar xzf "$CHAPEL_TAR"; }

cd "$INSTALL_DIR"

# ──────────────────────────────────────────────
# 4. chplconfig from the chosen conduit
# ──────────────────────────────────────────────
echo ">>> Writing chplconfig (CHPL_COMM_SUBSTRATE=$CONDUIT)..."
cat > chplconfig <<CHPLCFG
CHPL_COMM=gasnet
CHPL_COMM_SUBSTRATE=$CONDUIT
CHPL_LLVM=none
CHPLCFG
cat chplconfig

# ──────────────────────────────────────────────
# 5. Build
# ──────────────────────────────────────────────
export CHPL_HOME="$INSTALL_DIR"
source "$CHPL_HOME/util/setchplenv.bash"
echo ">>> Building Chapel ${CHAPEL_VERSION} ($CONDUIT conduit; this will take a while)..."
make -j"$(nproc)"

echo ""
echo "============================================"
echo "  Chapel ${CHAPEL_VERSION} build complete ($CONDUIT)!"
echo "============================================"
echo "  export CHPL_HOME=\"$CHPL_HOME\""
[[ "$CONDUIT" == "mpi" ]] && echo "  export PATH=\"$MPI_DIR/bin:\$PATH\"   # for mpirun/mpicc"
echo "  source \"\$CHPL_HOME/util/setchplenv.bash\""
echo "  chpl --version"
