#!/bin/bash

export DEBIAN_FRONTEND=noninteractive
set -euo pipefail

echo "[+] Instalando paquetes..."
apt-get update -qq
apt-get install vim python3 python3-pip python3-venv git -y >/dev/null
