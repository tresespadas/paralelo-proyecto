#!/bin/bash
#
# Runs inside test-master as a Vagrant shell provisioner (privileged=false).
# Re-execs as the `master` user so helm/kubectl hablan contra el kubeconfig
# de master (~/.kube/config).
#
# Despliega:
#   - Helm 4 (si no está)
#   - Grafana standalone con datasources Prometheus+Loki provisionados
#     declarativamente desde values/grafana.yaml (ya no hay POST /api/datasources)
#   - Prometheus standalone (chart prometheus-community/prometheus)
#   - Loki standalone en modo SingleBinary (chart grafana/loki)
#   - Promtail DaemonSet enviando logs a Loki por DNS interno
#
# Idempotente: re-ejecutable sin romper nada (helm upgrade --install,
# kubectl apply, chown — todos idempotentes por diseño).
#
# Prerequisitos:
#   - Cluster k8s levantado con setup-kubespray.sh (Fase 7 ya corrida — el
#     namespace 'monitoring' tiene que existir).
#   - /vagrant sincronizado con el repo (vagrant rsync si hace falta).
#
set -euo pipefail

# Re-exec como master si no estamos ya (Vagrant arranca como `vagrant`).
# El script sube a /tmp con modo 700 de vagrant, por eso le damos a+r antes
# de cambiar a master, que si no no puede ni leerlo.
if [ "$(id -un)" != "master" ]; then
  chmod a+r "$0"
  exec sudo -iu master bash "$0" "$@"
fi

MONITORING_NS="monitoring"
GRAFANA_NODE_IP="10.0.1.12"    # worker2 — mismo nodo que aloja los hostPath
GRAFANA_NODEPORT="30711"
PROMETHEUS_NODEPORT="30090"

###############################################################################
# Precondición: el cluster y el namespace monitoring tienen que existir
###############################################################################
if ! kubectl get namespace "$MONITORING_NS" >/dev/null 2>&1; then
  echo "[x] El namespace '$MONITORING_NS' no existe."
  echo "    Ejecuta antes: vagrant provision test-master --provision-with setup-kubespray"
  exit 1
fi

###############################################################################
# Fase 1: Instalar Helm 4 (si no está)
###############################################################################
echo "[!] Fase 1: Instalando Helm 4"
if command -v helm >/dev/null 2>&1; then
  echo "    Ya instalado: $(helm version --short)"
else
  curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
  chmod 700 /tmp/get_helm.sh
  bash /tmp/get_helm.sh
  rm -f /tmp/get_helm.sh
fi

###############################################################################
# Fase 2: Repos de Helm
###############################################################################
echo "[!] Fase 2: Añadiendo repos de Helm"
# `helm repo add` falla si el repo ya existe; con `|| true` lo hacemos idempotente.
helm repo add grafana              https://grafana.github.io/helm-charts              >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update

###############################################################################
# Fase 3: Pre-chown de hostPaths en worker2
###############################################################################
# fsGroup en el PodSpec NO recursiza sobre hostPath — por eso el chown manual
# es obligatorio. UID 472 = usuario 'grafana' en la imagen oficial;
# UID 65534 = 'nobody', usuario del server de Prometheus;
# UID 10001 = usuario que el chart de Loki configura en su podSecurityContext.
echo "[!] Fase 3: Preparando hostPaths en worker2"
ssh -o StrictHostKeyChecking=accept-new worker2@10.0.1.12 'bash -s' <<'REMOTE'
set -euo pipefail
sudo mkdir -p /mnt/data/grafana /mnt/data/prometheus /mnt/data/loki
sudo chown 472:472     /mnt/data/grafana
sudo chown 65534:65534 /mnt/data/prometheus
sudo chown 10001:10001 /mnt/data/loki
REMOTE

###############################################################################
# Fase 4: PV/PVC
###############################################################################
echo "[!] Fase 4: Aplicando PV/PVC"
kubectl apply -f /vagrant/manifests/storage/grafana-pv.yaml
kubectl apply -f /vagrant/manifests/storage/prometheus-pv.yaml
kubectl apply -f /vagrant/manifests/storage/loki-pv.yaml

###############################################################################
# Fase 5: Grafana standalone
###############################################################################
# --wait bloquea hasta que todos los recursos del release estén Ready, así la
# fase 7 (llamada a la API de Grafana) tiene garantía de que el pod existe.
echo "[!] Fase 5: Desplegando Grafana"
helm upgrade --install grafana grafana/grafana \
  --namespace "$MONITORING_NS" \
  -f /vagrant/values/grafana.yaml \
  --wait --timeout 5m

###############################################################################
# Fase 6: Prometheus standalone
###############################################################################
echo "[!] Fase 6: Desplegando Prometheus"
helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace "$MONITORING_NS" \
  -f /vagrant/values/prometheus.yaml \
  --wait --timeout 5m

###############################################################################
# Fase 7: Loki standalone (SingleBinary, hostPath en worker2)
###############################################################################
# El cableado del datasource Loki en Grafana se hace declarativamente vía
# values/grafana.yaml (sección 'datasources'), no aquí. El orden importa
# poco: Grafana se instaló en Fase 5 con la config del datasource ya
# cargada; mientras Loki no esté Ready, las queries fallan (esperado).
# Cuando este helm install termine, las queries empiezan a funcionar.
echo "[!] Fase 7: Desplegando Loki"
helm upgrade --install loki grafana/loki \
  --namespace "$MONITORING_NS" \
  -f /vagrant/values/loki.yaml \
  --wait --timeout 5m

###############################################################################
# Fase 8: Promtail DaemonSet (workers, push a Loki interno)
###############################################################################
# Promtail corre solo en worker1+worker2 — el override 'tolerations: []'
# en values/promtail.yaml impide que toleré el taint del control-plane,
# así el DaemonSet evita master automáticamente.
echo "[!] Fase 8: Desplegando Promtail"
helm upgrade --install promtail grafana/promtail \
  --namespace "$MONITORING_NS" \
  -f /vagrant/values/promtail.yaml \
  --wait --timeout 5m

###############################################################################
# Fase 9: Resumen
###############################################################################
# Leemos la contraseña del admin desde el Secret que el chart gestiona —
# así el output siempre refleja la pass real, no la del values en el
# momento de la primera instalación (helm no rota Secrets en upgrades).
admin_pass=$(kubectl get secret -n "$MONITORING_NS" grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d)

echo
echo "[+] Lab de monitoring desplegado."
echo "    - Grafana:    http://${GRAFANA_NODE_IP}:${GRAFANA_NODEPORT}   (admin / ${admin_pass})"
echo "    - Prometheus: http://${GRAFANA_NODE_IP}:${PROMETHEUS_NODEPORT}"
echo "    - Loki:       solo interno (http://loki.${MONITORING_NS}.svc.cluster.local:3100)"
echo "    - Datasources cableados vía Grafana provisioning (values/grafana.yaml)"
echo
kubectl get pods -n "$MONITORING_NS"
