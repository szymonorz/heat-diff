#!/usr/bin/env bash
set -euo pipefail

VM_DIR="$HOME/qemu-vms/ubuntu2004-chapel"
DISK_IMG="$VM_DIR/ubuntu2004.qcow2"
DISK_SIZE="60G"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
CLOUD_IMG="$VM_DIR/focal-server-cloudimg-amd64.img"
SEED_ISO="$VM_DIR/seed.iso"
SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"

mkdir -p "$VM_DIR"

# --- Download Ubuntu 20.04 cloud image ---
if [[ ! -f "$CLOUD_IMG" ]]; then
    echo ">>> Downloading Ubuntu 20.04 cloud image..."
    wget -O "$CLOUD_IMG" "$CLOUD_IMG_URL"
else
    echo ">>> Cloud image already downloaded."
fi

# --- Create disk from cloud image ---
if [[ ! -f "$DISK_IMG" ]]; then
    echo ">>> Creating disk image from cloud image..."
    cp "$CLOUD_IMG" "$DISK_IMG"
    qemu-img resize "$DISK_IMG" "$DISK_SIZE"
else
    echo ">>> Disk image already exists."
fi

# --- Create cloud-init seed ISO ---
echo ">>> Creating cloud-init seed ISO..."

SEED_DIR="$VM_DIR/seed"
mkdir -p "$SEED_DIR"

cat > "$SEED_DIR/meta-data" << EOF
instance-id: chapel-dev-001
local-hostname: chapel-dev
EOF

cat > "$SEED_DIR/user-data" << EOF
#cloud-config
hostname: chapel-dev
manage_etc_hosts: true
users:
  - name: chapel
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: chapel
    ssh_authorized_keys:
      - ${SSH_PUBKEY}
ssh_pwauth: true
package_update: true
packages:
  - openssh-server
  - gcc
  - g++
  - make
  - m4
  - perl
  - python3
  - python3-dev
  - cmake
  - git
  - pkg-config
  - wget
  - curl
  - libgmp-dev
runcmd:
  - systemctl enable ssh
  - systemctl start ssh
  - su - chapel -c 'ssh-keygen -t ed25519 -f /home/chapel/.ssh/id_ed25519 -N "" -q'
  - su - chapel -c 'cat /home/chapel/.ssh/id_ed25519.pub >> /home/chapel/.ssh/authorized_keys'
  - su - chapel -c 'chmod 600 /home/chapel/.ssh/authorized_keys'
  - su - chapel -c 'ssh-keyscan -H localhost >> /home/chapel/.ssh/known_hosts 2>/dev/null'
EOF

genisoimage -output "$SEED_ISO" -volid cidata -joliet -rock \
    "$SEED_DIR/user-data" "$SEED_DIR/meta-data" 2>/dev/null

echo ">>> Setup complete. Files in $VM_DIR"
echo ">>> Use start-vm.sh to launch the VM."
