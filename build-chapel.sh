#!/usr/bin/env bash
#
# Run this script INSIDE the Ubuntu 20.04 QEMU guest.
# It installs dependencies, downloads Chapel 2.7.0, applies the
# chplconfig, and builds Chapel.
#
set -eo pipefail

CHAPEL_VERSION="2.7.0"
CHAPEL_TAR="chapel-${CHAPEL_VERSION}.tar.gz"
CHAPEL_URL="https://github.com/chapel-lang/chapel/releases/download/${CHAPEL_VERSION}/${CHAPEL_TAR}"
INSTALL_DIR="$HOME/chapel-${CHAPEL_VERSION}"

# ──────────────────────────────────────────────
# 1. Install build dependencies
# ──────────────────────────────────────────────
echo ">>> Installing build dependencies..."
#sudo apt-get update
sudo apt-get install -y \
    gcc g++ make m4 perl python3 python3-dev python3-pip \
    bash git pkg-config \
    wget curl \
    libgmp-dev \
    openssh-server

CMAKE_MIN="3.20.0"
CMAKE_CUR=$(cmake --version 2>/dev/null | head -1 | awk '{print $3}')
if [[ -z "$CMAKE_CUR" ]] || [[ "$(printf '%s\n' "$CMAKE_MIN" "$CMAKE_CUR" | sort -V | head -1)" != "$CMAKE_MIN" ]]; then
    echo ">>> System cmake ($CMAKE_CUR) is too old, installing newer cmake via pip..."
    pip3 install cmake
    export PATH="$HOME/.local/bin:$PATH"
    echo ">>> cmake version: $(cmake --version | head -1)"
fi

# ──────────────────────────────────────────────
# 2. Download and extract Chapel
# ──────────────────────────────────────────────
#cd "$HOME"

if [[ -f "$CHAPEL_TAR" ]] && ! gzip -t "$CHAPEL_TAR" 2>/dev/null; then
    echo ">>> Existing tarball is corrupted, removing..."
    rm -f "$CHAPEL_TAR"
fi

if [[ ! -f "$CHAPEL_TAR" ]]; then
    echo ">>> Downloading Chapel ${CHAPEL_VERSION}..."
    wget "$CHAPEL_URL"
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
    echo ">>> Extracting Chapel..."
    tar xzf "$CHAPEL_TAR"
fi

cd "$INSTALL_DIR"

# ──────────────────────────────────────────────
# 3. Write chplconfig
# ──────────────────────────────────────────────
echo ">>> Writing chplconfig..."
cat > chplconfig << 'CHPLCFG'
CHPL_COMM=gasnet
CHPL_LLVM=none
CHPLCFG

echo ">>> chplconfig contents:"
cat chplconfig
echo ""

# ──────────────────────────────────────────────
# 4. Set up Chapel environment
# ──────────────────────────────────────────────
export CHPL_HOME="$INSTALL_DIR"
source "$CHPL_HOME/util/setchplenv.bash"

# ──────────────────────────────────────────────
# 5. Build Chapel
# ──────────────────────────────────────────────
echo ">>> Building Chapel ${CHAPEL_VERSION} (this will take a while)..."
make -j"$(nproc)"

echo ""
echo "============================================"
echo "  Chapel ${CHAPEL_VERSION} build complete!"
echo "============================================"
echo ""
echo "Add this to your ~/.bashrc to use Chapel:"
echo ""
echo "  export CHPL_HOME=\"$CHPL_HOME\""
echo "  source \"\$CHPL_HOME/util/setchplenv.bash\""
echo ""
echo "Then verify with: chpl --version"
