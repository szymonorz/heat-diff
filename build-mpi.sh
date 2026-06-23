#!/usr/bin/env bash
#
# Build MPICH from source into a self-contained prefix (no root, no package manager).
# Used by distribute-chapel.sh when --conduit mpi is requested, but can be run standalone.
#
# Why from source: the GASNet mpi-conduit needs an MPI whose version is IDENTICAL on every
# node of a job. Distro packages can't guarantee that across a heterogeneous cluster
# (e.g. Fedora openmpi 5.0.5 vs Void openmpi 5.0.10), so we build one tree and ship it.
#
# ch3:sock device = plain TCP sockets: simple, dependency-free, and gives TCP flow control
# (the whole point — it survives the packet loss / incast that makes the udp conduit abort).
#
set -eo pipefail

MPICH_VERSION="${MPICH_VERSION:-4.2.3}"
PREFIX=""
JOBS=""

usage() {
    cat <<EOF
Usage: $0 --prefix DIR [OPTIONS]

Build MPICH ${MPICH_VERSION} from source into DIR (idempotent: skips if DIR/bin/mpicc exists).

Options:
  -p, --prefix DIR   Install prefix (required), e.g. /home/chapel/workspace/mpi
  -j, --jobs N       Parallel make jobs (default: nproc, capped at 8)
  -v, --version VER  MPICH version (default: ${MPICH_VERSION}, or \$MPICH_VERSION)
  -h, --help         Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--prefix)  PREFIX="$2"; shift 2 ;;
        -j|--jobs)    JOBS="$2"; shift 2 ;;
        -v|--version) MPICH_VERSION="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

[[ -n "$PREFIX" ]] || { echo "Error: --prefix is required." >&2; exit 1; }

# Idempotent: already built?
if [[ -x "$PREFIX/bin/mpicc" && -x "$PREFIX/bin/mpirun" ]]; then
    echo ">>> MPICH already present at $PREFIX (skipping build)"
    "$PREFIX/bin/mpichversion" | head -1 || true
    exit 0
fi

# Minimal dep check (no install — fail fast with guidance).
MISSING=()
for c in gcc make wget; do command -v "$c" >/dev/null 2>&1 || MISSING+=("$c"); done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "Error: missing build tools: ${MISSING[*]}" >&2
    echo "  Fedora: sudo dnf install gcc make wget" >&2
    echo "  Void:   sudo xbps-install -S gcc make wget" >&2
    exit 1
fi

if [[ -z "$JOBS" ]]; then
    JOBS=$(nproc); (( JOBS > 8 )) && JOBS=8
fi

TARBALL="mpich-${MPICH_VERSION}.tar.gz"
URL="https://www.mpich.org/static/downloads/${MPICH_VERSION}/${TARBALL}"
BUILD_PARENT="$(dirname "$PREFIX")"
cd "$BUILD_PARENT"

if [[ -f "$TARBALL" ]] && ! gzip -t "$TARBALL" 2>/dev/null; then
    echo ">>> Existing tarball corrupt, removing..."; rm -f "$TARBALL"
fi
[[ -f "$TARBALL" ]] || { echo ">>> Downloading MPICH ${MPICH_VERSION}..."; wget -q "$URL"; }

echo ">>> Extracting..."
rm -rf "mpich-${MPICH_VERSION}"
tar xzf "$TARBALL"
cd "mpich-${MPICH_VERSION}"

echo ">>> Configuring (prefix=$PREFIX, ch3:sock, no fortran)..."
./configure --prefix="$PREFIX" --disable-fortran --with-device=ch3:sock --disable-static \
    > configure.log 2>&1

echo ">>> Building (make -j${JOBS})..."
make -j"$JOBS" > make.log 2>&1

echo ">>> Installing..."
make install > install.log 2>&1

echo ">>> MPICH build complete: $PREFIX"
"$PREFIX/bin/mpichversion" | head -2
