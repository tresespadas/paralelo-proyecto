#!/bin/bash

NETWORK_NAME="red-prueba"
NETWORK_FILE="$(dirname "$0")/../network/red-prueba.xml"

# Check if network exists in libvirt
if virsh -c qemu:///system net-info "$NETWORK_NAME" &>/dev/null; then
  # Compare active config with local XML (ignore UUIDs, MACs, and whitespace differences)
  ACTIVE=$(virsh -c qemu:///system net-dumpxml "$NETWORK_NAME" | grep -v '<uuid>' | grep -v '<mac address=' | grep -v 'connections=' | sed 's/^ *//')
  LOCAL=$(cat "$NETWORK_FILE" | grep -v '<uuid>' | grep -v '<mac address=' | sed 's/^ *//')

  if [ "$ACTIVE" != "$LOCAL" ]; then
    echo "[+] Red: $NETWORK_NAME cambió la configuración, recreándola..."
    virsh -c qemu:///system net-destroy "$NETWORK_NAME" 2>/dev/null || true
    virsh -c qemu:///system net-undefine "$NETWORK_NAME" 2>/dev/null || true
    virsh -c qemu:///system net-define "$NETWORK_FILE"
    virsh -c qemu:///system net-start "$NETWORK_NAME"
  fi
else
  # Network doesn't exist, create it
  virsh -c qemu:///system net-define "$NETWORK_FILE"
  virsh -c qemu:///system net-start "$NETWORK_NAME"
fi

virsh -c qemu:///system net-autostart "$NETWORK_NAME" 2>/dev/null || true

echo "[+] Red: $NETWORK_NAME está operativa"
