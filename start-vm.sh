#!/usr/bin/env bash
set -euo pipefail

VM_DIR="$HOME/qemu-vms/ubuntu2004-chapel"
DISK_IMG="$VM_DIR/ubuntu2004.qcow2"
SEED_ISO="$VM_DIR/seed.iso"
RAM="8G"
CPUS="4"
SSH_HOST_PORT="2222"
MODE="${1:-graphical}"

if [[ ! -f "$DISK_IMG" ]]; then
    echo "ERROR: Disk image not found. Run setup-vm.sh first."
    exit 1
fi

echo ">>> Starting Ubuntu 20.04 VM (mode: $MODE)..."
echo "    SSH: ssh -p $SSH_HOST_PORT chapel@localhost"

COMMON_ARGS=(
    -enable-kvm
    -m "$RAM"
    -smp "$CPUS"
    -cpu host
    -drive "file=$DISK_IMG,format=qcow2,if=virtio"
    -drive "file=$SEED_ISO,format=raw,if=virtio"
    -device virtio-net-pci,netdev=net0
    -netdev "user,id=net0,hostfwd=tcp::${SSH_HOST_PORT}-:22"
    -name "Ubuntu 20.04 Chapel Dev"
)

if [[ "$MODE" == "headless" ]]; then
    qemu-system-x86_64 "${COMMON_ARGS[@]}" \
        -nographic \
        -serial mon:stdio
else
    qemu-system-x86_64 "${COMMON_ARGS[@]}" \
        -vga virtio \
        -display gtk \
        -usb \
        -device usb-tablet
fi
