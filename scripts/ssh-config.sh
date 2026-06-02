#!/bin/bash

SSH_CONFIG="$HOME/.ssh/config"
MARKER_START="# BEGIN paralelo-proyecto"
MARKER_END="# END paralelo-proyecto"

BLOCK=$(vagrant ssh-config 2>/dev/null)

if [ -z "$BLOCK" ]; then
  echo "Failed to get vagrant ssh-config"
  exit 1
fi

# Replace User vagrant with custom users per host
BLOCK=$(echo "$BLOCK" | awk '
  /^Host test-master/  { user="master" }
  /^Host test-worker1/ { user="worker1" }
  /^Host test-worker2/ { user="worker2" }
  /User vagrant/ && user { gsub(/User vagrant/, "User " user); user="" }
  { print }
')

mkdir -p "$HOME/.ssh"

if [ -f "$SSH_CONFIG" ]; then
  CLEANED=$(awk -v start="$MARKER_START" -v end="$MARKER_END" \
    '$0 == start {skip=1; next} $0 == end {skip=0; next} !skip' "$SSH_CONFIG")
  echo "$CLEANED" >"$SSH_CONFIG"
else
  touch "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
fi

printf '%s\n%s\n%s\n' "$MARKER_START" "$BLOCK" "$MARKER_END" >>"$SSH_CONFIG"

echo "[+] Configuración SSH actualizada para paralelo-proyecto"
