#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISK_DIR="$SCRIPT_DIR/../disks"

mkdir -p "$DISK_DIR"

# Grant libvirt-qemu traverse access to reach the disks directory
# (only adds ACL entries, harmless if already set)
setfacl -m u:libvirt-qemu:x "$HOME" 2>/dev/null || true
setfacl -m u:libvirt-qemu:rwx "$DISK_DIR" 2>/dev/null || true

declare -A SIZES=(
  ["test-master"]=40G
  ["test-worker1"]=20G
  ["test-worker2"]=20G
)

for node in test-master test-worker1 test-worker2; do
  DISK="$DISK_DIR/${node}-data.qcow2"
  if [ -f "$DISK" ]; then
    echo "[!] El disco $DISK ya existe, omitiendo..."
  else
    qemu-img create -f qcow2 "$DISK" "${SIZES[$node]}"
    setfacl -m u:libvirt-qemu:rw "$DISK"
    echo "[+] Creado $DISK (${SIZES[$node]})"
  fi
done
