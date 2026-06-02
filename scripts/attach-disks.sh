#!/bin/bash

VIRSH="virsh -c qemu:///system"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
DISK_DIR="$PROJECT_DIR/disks"

for node in test-master test-worker1 test-worker2; do
  DISK="$(realpath "$DISK_DIR/${node}-data.qcow2")"
  ID_FILE="$PROJECT_DIR/.vagrant/machines/${node}/libvirt/id"

  if [ ! -f "$ID_FILE" ]; then
    echo "[!] ERROR: No se ha encontrado ID de dominio de libvirt para $node — omitiendo"
    continue
  fi

  DOMAIN=$(cat "$ID_FILE")

  # Check if vdb is already attached
  if $VIRSH domblklist "$DOMAIN" | grep -q "vdb"; then
    echo "[!] $node: vdb ya se encuentra conectado"
  else
    echo "[+] $node: conectado $DISK como vdb"
    $VIRSH attach-disk "$DOMAIN" "$DISK" vdb \
      --driver qemu --subdriver qcow2 --persistent
  fi

  # Format and mount inside the VM via SSH
  ssh -o StrictHostKeyChecking=no "$node" bash -s <<'REMOTE'
    set -e

    # Wait briefly for the device to appear
    for i in $(seq 1 10); do
      [ -b /dev/vdb ] && break
      sleep 1
    done

    if [ ! -b /dev/vdb ]; then
      echo "[!] ERROR: /dev/vdb no encontrado"
      exit 1
    fi

    # Format only if no filesystem exists
    if ! sudo blkid /dev/vdb &>/dev/null; then
      echo "[+] Formateando /dev/vdb como ext4"
      sudo mkfs.ext4 -q /dev/vdb
    else
      echo "[!] /dev/vdb already ya tiene un sistema de ficheros"
    fi

    # Create mount point
    sudo mkdir -p /mnt/data

    # Add fstab entry if not present
    if ! grep -q '/dev/vdb' /etc/fstab; then
      echo '/dev/vdb /mnt/data ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab >/dev/null
      echo "[!] Entrada añadida en /etc/fstab "
    fi

    # Mount if not already mounted
    if ! mountpoint -q /mnt/data; then
      sudo mount /mnt/data
      echo "[!] Montaje realizado en /mnt/data"
    else
      echo "[!] /mnt/data ya se encuentra montado"
    fi
REMOTE

  echo "[*] $node: terminado"
  echo
done
