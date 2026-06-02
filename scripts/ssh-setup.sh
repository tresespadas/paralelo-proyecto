#!/bin/bash

export DEBIAN_FRONTEND=noninteractive
set -euo pipefail

USERNAME="$1"

# Shared lab keypair for inter-node SSH (master <-> workers)
SSH_PRIVATE_KEY="-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACA979XNR/W5ElhvK2gLBm8aDfcQRoiiln+/8Bavqb+daQAAAJiwBbnRsAW5
0QAAAAtzc2gtZWQyNTUxOQAAACA979XNR/W5ElhvK2gLBm8aDfcQRoiiln+/8Bavqb+daQ
AAAEBbgSKL6zh/DDhOC4bMFo4TcJnija0qbSt+vKQiVkpCxT3v1c1H9bkSWG8raAsGbxoN
9xBGiKKWf7/wFq+pv51pAAAAFWxhYkBwYXJhbGVsby1wcm95ZWN0bw==
-----END OPENSSH PRIVATE KEY-----"
SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID3v1c1H9bkSWG8raAsGbxoN9xBGiKKWf7/wFq+pv51p lab@paralelo-proyecto"

echo "[+] Configurando usuario: $USERNAME"

if ! id "$USERNAME" &>/dev/null; then
  useradd -m -s /bin/bash "$USERNAME"
  echo "$USERNAME:$USERNAME" | chpasswd
  usermod -aG sudo "$USERNAME"
  echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/$USERNAME
fi

USER_HOME="/home/$USERNAME"
mkdir -p "$USER_HOME/.ssh"

# Host -> VM SSH (copy vagrant's key)
cp /home/vagrant/.ssh/authorized_keys "$USER_HOME/.ssh/authorized_keys"

# Inter-node SSH (shared lab keypair)
echo "$SSH_PRIVATE_KEY" >"$USER_HOME/.ssh/id_ed25519"
echo "$SSH_PUBLIC_KEY" >"$USER_HOME/.ssh/id_ed25519.pub"
if ! grep -qF "$SSH_PUBLIC_KEY" "$USER_HOME/.ssh/authorized_keys" 2>/dev/null; then
  echo "$SSH_PUBLIC_KEY" >>"$USER_HOME/.ssh/authorized_keys"
fi

# Skip host key verification for lab subnet
cat >"$USER_HOME/.ssh/config" <<EOF
Host 10.0.1.*
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/id_ed25519"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chmod 644 "$USER_HOME/.ssh/id_ed25519.pub"
chmod 644 "$USER_HOME/.ssh/config"
