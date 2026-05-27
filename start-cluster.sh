#!/usr/bin/env bash
set -euo pipefail

CLUSTER_DIR="$HOME/qemu-vms/chapel-cluster"
RAM="8G"
CPUS="4"
MCAST_ADDR="230.0.0.1:1234"

for vm in vm1 vm2; do
    VM_DIR="$CLUSTER_DIR/$vm"
    DISK="$VM_DIR/disk.qcow2"
    SEED="$VM_DIR/seed.iso"

    if [[ ! -f "$DISK" ]]; then
        echo "ERROR: $DISK not found." >&2
        exit 1
    fi

    if [[ "$vm" == "vm1" ]]; then
        SSH_PORT="2222"
        VM_NAME="chapel-node1"
    else
        SSH_PORT="2223"
        VM_NAME="chapel-node2"
    fi

    echo ">>> Starting $VM_NAME (SSH: localhost:$SSH_PORT)..."

    qemu-system-x86_64 \
        -enable-kvm \
        -m "$RAM" \
        -smp "$CPUS" \
        -cpu host \
        -drive "file=$DISK,format=qcow2,if=virtio" \
        -drive "file=$SEED,format=raw,if=virtio" \
        -device virtio-net-pci,netdev=nat0 \
        -netdev "user,id=nat0,hostfwd=tcp::${SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=cluster0 \
        -netdev "socket,id=cluster0,mcast=${MCAST_ADDR}" \
        -name "$VM_NAME" \
        -display none \
        -daemonize \
        -pidfile "$VM_DIR/qemu.pid" \
        2>&1 | tail -5

    echo ">>> $VM_NAME started (PID: $(cat "$VM_DIR/qemu.pid"))"
done

echo ""
echo "Both VMs started."
echo "  VM1 (chapel-node1): ssh -p 2222 chapel@localhost"
echo "  VM2 (chapel-node2): ssh -p 2223 chapel@localhost"
echo "  Inter-VM: 10.0.0.1 <-> 10.0.0.2"
echo ""
echo "To stop: kill \$(cat $CLUSTER_DIR/vm1/qemu.pid) \$(cat $CLUSTER_DIR/vm2/qemu.pid)"
