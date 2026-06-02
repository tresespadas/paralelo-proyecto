#!/bin/bash
#
# Runs inside test-master as a Vagrant shell provisioner (privileged=false).
# Re-execs as the `master` user so everything lands under /home/master/.
# Deploys a 3-node Kubernetes cluster with kubespray v2.26.0.
# Assumes config.sh + ssh-setup.sh have already run on all nodes
# (python3, git, custom users, shared lab keypair, passwordless sudo).
#
set -euo pipefail

# Re-exec as master if we're not already (Vagrant runs this as `vagrant`).
# The uploaded script in /tmp is mode 700 owned by vagrant, so master can't
# read it until we widen the read bit (vagrant owns it, no sudo needed).
if [ "$(id -un)" != "master" ]; then
  chmod a+r "$0"
  exec sudo -iu master bash "$0" "$@"
fi

INVENTORY_NAME="cluster-k8-paralelo"
KUBESPRAY_TAG="v2.26.0"
KUBESPRAY_DIR="$HOME/kubespray"
VENV_DIR="$HOME/kubespray-venv"
INV_DIR="$KUBESPRAY_DIR/inventory/$INVENTORY_NAME"

###############################################################################
# Phase 1: Clone kubespray
###############################################################################
echo "[!] Fase 1: Clonando kubespray ${KUBESPRAY_TAG}"
if [ -d "$KUBESPRAY_DIR/.git" ]; then
  git -C "$KUBESPRAY_DIR" fetch --tags
  git -C "$KUBESPRAY_DIR" checkout "$KUBESPRAY_TAG"
else
  git clone --branch "$KUBESPRAY_TAG" --depth 1 \
    https://github.com/kubernetes-sigs/kubespray.git "$KUBESPRAY_DIR"
fi

###############################################################################
# Phase 2: Python virtualenv + requirements
###############################################################################
echo "[!] Fase 2: Montando entorno virtual en Python"
[ -d "$VENV_DIR" ] || python3 -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
pip install -q -U pip
pip install -q -r "$KUBESPRAY_DIR/requirements.txt"

###############################################################################
# Phase 3: Generate inventory (hosts.yml with ansible_user per host)
###############################################################################
echo "[!] Fase 3: Generando inventorio en $INV_DIR"
mkdir -p "$INV_DIR/group_vars"

cat >"$INV_DIR/hosts.yml" <<'INVENTORY'
all:
  hosts:
    master:
      ansible_host: 10.0.1.10
      ansible_user: master
      ip: 10.0.1.10
      access_ip: 10.0.1.10
    worker1:
      ansible_host: 10.0.1.11
      ansible_user: worker1
      ip: 10.0.1.11
      access_ip: 10.0.1.11
    worker2:
      ansible_host: 10.0.1.12
      ansible_user: worker2
      ip: 10.0.1.12
      access_ip: 10.0.1.12
  children:
    kube_control_plane:
      hosts:
        master:
    kube_node:
      hosts:
        worker1:
        worker2:
    etcd:
      hosts:
        master:
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
    calico_rr:
      hosts: {}
INVENTORY

###############################################################################
# Phase 4: Configure group_vars (copy sample, switch CNI to flannel)
###############################################################################
echo "[!] Fase 4: Configurando group_vars"
cp -r "$KUBESPRAY_DIR/inventory/sample/group_vars/." "$INV_DIR/group_vars/"

sed -i 's/^kube_network_plugin:.*/kube_network_plugin: flannel/' \
  "$INV_DIR/group_vars/k8s_cluster/k8s-cluster.yml"

###############################################################################
# Phase 5: Run ansible-playbook
###############################################################################
echo "[!] Fase 5: Ejecutándo ansible-playbook"
cd "$KUBESPRAY_DIR"
ansible-playbook -i "inventory/$INVENTORY_NAME/hosts.yml" --become cluster.yml

###############################################################################
# Phase 6: kubeconfig for local kubectl
###############################################################################
echo "[!] Fase 6: Instalando kubeconfig para el usuario master"
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo '[+] NODOS'
kubectl get nodes
echo '[+] PODS'
kubectl get pods -A

echo "[+] Despliegue de Kubespray exitoso"

###############################################################################
# Phase 7: creando namespaces
###############################################################################
echo "[!] Fase 7: Creando namespaces (vulnerable, monitoring, security)"
kubectl create namespace vulnerable
kubectl create namespace monitoring
kubectl create namespace security

#echo "[+] Fase 7: Instalando helm para el usuario master"
###############################################################################
# Phase 8: installing helm
###############################################################################
#echo "[+] Fase 7: Instalando helm para el usuario master"

#curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
#chmod 700 get_helm.sh
#bash get_helm.sh
