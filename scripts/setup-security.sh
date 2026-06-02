#!/bin/bash
#
# Runs inside test-master as a Vagrant shell provisioner (privileged=false).
# Re-execs as the `master` user — mismo pattern que setup-lab.sh — para que
# helm/kubectl usen el kubeconfig real del cluster (~/.kube/config).
#
# Despliega el stack de seguridad COMPLETO:
#   - Falco standalone (chart upstream falcosecurity/falco) — DaemonSet
#     en workers, driver modern_ebpf, output JSON a stdout
#   - Suricata standalone (chart custom charts/suricata) — DaemonSet en
#     worker1 con hostNetwork, sidecar tail eve.json → stdout
#   - DVWA (chart custom charts/dvwa) — Deployment 1 replica en worker1
#     con MySQL embebido (sin persistencia — ver charts/dvwa/values.yaml)
#
# Pipeline final de eventos:
#   Falco/Suricata stdout → Promtail → Loki → Grafana
#   Tráfico Kali → eth0 worker1 → Suricata af-packet → eve.json → ↑
#   Tráfico Kali → DVWA :30430 → Apache logs (ya en stdout)        → ↑
#
# Precondición fuerte: el stack de monitoring (Loki + Promtail) tiene que
# estar corriendo. Sin Promtail, los eventos se generan pero nunca llegan
# a Loki — el script aborta antes de instalar nada para evitar dejar
# detectores "huérfanos".
#
# Idempotente: re-ejecutable sin romper nada (helm upgrade --install,
# kubectl apply con dry-run de namespace, mkdir -p, chown idempotente).
#
# Prerequisitos:
#   - Cluster k8s levantado con setup-kubespray.sh
#   - Stack de monitoring desplegado con setup-lab.sh
#   - /vagrant sincronizado con el repo (vagrant rsync si hace falta)
#
set -euo pipefail

# Re-exec como master si no estamos ya. Vagrant arranca como `vagrant`,
# que no tiene ~/.kube/config. El chmod a+r es necesario porque el script
# llega a /tmp con modo 700 y el user master no podría leerlo.
if [ "$(id -un)" != "master" ]; then
  chmod a+r "$0"
  exec sudo -iu master bash "$0" "$@"
fi

MONITORING_NS="monitoring"
SECURITY_NS="security"
VULNERABLE_NS="vulnerable"

DVWA_NODE_IP="10.0.1.11"  # worker1 — donde corre DVWA + Suricata
DVWA_NODEPORT="30430"

###############################################################################
# Fase 1: Precondiciones — el stack de monitoring tiene que estar listo
###############################################################################
# Detectores sin Promtail = eventos perdidos. Verificamos que el namespace
# exista y que el DaemonSet de Promtail tenga al menos 1 pod Ready.
echo "[!] Fase 1: Verificando precondiciones del stack de monitoring"

if ! kubectl get namespace "$MONITORING_NS" >/dev/null 2>&1; then
  echo "[x] El namespace '$MONITORING_NS' no existe."
  echo "    Ejecuta antes: vagrant provision test-master --provision-with setup-lab"
  exit 1
fi

promtail_ready=$(kubectl get ds -n "$MONITORING_NS" promtail \
  -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
if [ "$promtail_ready" -lt 1 ]; then
  echo "[x] Promtail no tiene pods Ready en el ns '$MONITORING_NS'."
  echo "    Sin Promtail los eventos no llegan a Loki."
  echo "    Ejecuta antes: vagrant provision test-master --provision-with setup-lab"
  exit 1
fi
echo "    Promtail Ready en $promtail_ready nodo(s) — OK"

###############################################################################
# Fase 2: Repos de Helm
###############################################################################
# Solo Falco viene de un repo upstream. Suricata y DVWA son charts custom
# en charts/ — se instalan apuntando a la ruta local, sin repo.
#
# OJO con el typo del nombre: 'falcosecurity' (sin 'n'). Lección del vault:
# `helm repo add` no valida nombres — un typo (falconsecurity) se añade
# silenciosamente y `helm install` falla con "repo not found" sin pista
# de typo. El `helm repo update` posterior valida que resuelve.
echo "[!] Fase 2: Añadiendo repo Helm de Falco"
helm repo add falcosecurity https://falcosecurity.github.io/charts >/dev/null 2>&1 || true
helm repo update

###############################################################################
# Fase 3: Namespaces
###############################################################################
# kubectl create con --dry-run + apply -f - es el patrón idempotente
# canónico: si el ns ya existe, apply no hace nada; si no, lo crea.
# Evita el `|| true` que enmascararía errores distintos a AlreadyExists.
#
# Dos namespaces: 'security' (detectores) + 'vulnerable' (DVWA).
# Separación deliberada — un compromiso de DVWA no debe ver Falco/Suricata.
echo "[!] Fase 3: Asegurando namespaces '$SECURITY_NS' y '$VULNERABLE_NS'"
for ns in "$SECURITY_NS" "$VULNERABLE_NS"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

###############################################################################
# Fase 4: Falco standalone
###############################################################################
# --wait bloquea hasta que el DaemonSet tenga todos los pods Ready
# (initContainer falcoctl-artifact-install + main + sidecar follow).
# En kernel 5.15 con modern_ebpf el arranque tarda ~30-60s.
echo "[!] Fase 4: Desplegando Falco"
helm upgrade --install falco falcosecurity/falco \
  --namespace "$SECURITY_NS" \
  -f /vagrant/values/falco.yaml \
  --wait --timeout 5m

###############################################################################
# Fase 5: Suricata (chart custom)
###############################################################################
# helm install apuntando a la RUTA LOCAL del chart, no a un repo. La ruta
# /vagrant/charts/suricata es el directorio sincronizado con el repo del host.
#
# --wait: para un DaemonSet con replicas=1 (por nodeSelector) significa
# esperar a que ese único pod esté Ready. El initContainer suricata-update
# tarda ~30s descargando ET Open la primera vez (~30k reglas).
#
# NB: NO hay fase de PV/PVC para DVWA. La imagen vulnerables/web-dvwa trae
# la BD MariaDB horneada en la imagen y su entrypoint NO ejecuta
# mysql_install_db — montar un PVC encima de /var/lib/mysql shadowea la BD
# pre-cocinada y mysqld muere con "Table 'mysql.user' doesn't exist".
# Decisión: emptyDir implícito (sin persistencia). Reset de DVWA es parte
# del workflow normal del lab. Ver charts/dvwa/values.yaml.
echo "[!] Fase 5: Desplegando Suricata"
helm upgrade --install suricata /vagrant/charts/suricata \
  --namespace "$SECURITY_NS" \
  -f /vagrant/values/suricata.yaml \
  --wait --timeout 5m

###############################################################################
# Fase 6: DVWA (chart custom)
###############################################################################
# Mismo patrón que Suricata: chart local, values overrides aparte.
# Sin PVC — el datadir de MariaDB vive en el filesystem efímero del pod.
# Cada restart obliga a re-hacer setup desde /setup.php (~5s manual).
echo "[!] Fase 6: Desplegando DVWA"
helm upgrade --install dvwa /vagrant/charts/dvwa \
  --namespace "$VULNERABLE_NS" \
  -f /vagrant/values/dvwa.yaml \
  --wait --timeout 5m

###############################################################################
# Fase 7: WebGoat (chart custom)
###############################################################################
# Java + Spring Boot autocontenido. Tarda ~60-90s en pasar Ready la primera
# vez (classpath scan + H2 init). El chart pone initialDelaySeconds=120 en
# el liveness probe para que kubelet no lo mate prematuramente.
#
# JAVA_TOOL_OPTIONS=-Xmx384m acota el heap para que no rebase el limit
# de 512Mi del container — sin ese cap, Spring Boot crece hasta donde le
# deja el host y dispara OOMKilled (exit 137) en worker1 (apretado de RAM).
#
# --timeout 8m: holgura para el cold-start. Pull de la imagen (~700MB) +
# arranque JVM puede llegar a 5min en redes lentas la primera vez.
echo "[!] Fase 7: Desplegando WebGoat"
helm upgrade --install webgoat /vagrant/charts/webgoat \
  --namespace "$VULNERABLE_NS" \
  -f /vagrant/values/webgoat.yaml \
  --wait --timeout 8m

###############################################################################
# Fase 8: Juice Shop (chart custom)
###############################################################################
# Node.js + Express + sqlite efímera. Mucho más liviano que WebGoat —
# Ready en ~15s. Sin env vars críticas, defaults de la imagen sirven.
echo "[!] Fase 8: Desplegando Juice Shop"
helm upgrade --install juiceshop /vagrant/charts/juiceshop \
  --namespace "$VULNERABLE_NS" \
  -f /vagrant/values/juiceshop.yaml \
  --wait --timeout 5m

###############################################################################
# Fase 9: Resumen
###############################################################################
WEBGOAT_NODEPORT="30380"
JUICESHOP_NODEPORT="31592"

echo
echo "[+] Stack de seguridad desplegado."
echo "    - Falco       → ns '$SECURITY_NS'   (workers, master excluido)"
echo "    - Suricata    → ns '$SECURITY_NS'   (solo worker1, hostNetwork)"
echo "    - DVWA        → ns '$VULNERABLE_NS' (worker1, MySQL efímero)"
echo "    - WebGoat     → ns '$VULNERABLE_NS' (worker1, H2 efímera)"
echo "    - Juice Shop  → ns '$VULNERABLE_NS' (worker1, sqlite efímera)"
echo
echo "    Endpoints (acceso desde host o Kali):"
echo "      DVWA:        http://${DVWA_NODE_IP}:${DVWA_NODEPORT}/login.php"
echo "        Setup inicial: visitar /setup.php → 'Create / Reset Database'"
echo "        Credenciales:  admin / password"
echo "      WebGoat:     http://${DVWA_NODE_IP}:${WEBGOAT_NODEPORT}/WebGoat (case-sensitive)"
echo "        Crear cuenta nueva en el form de registro la primera vez"
echo "      Juice Shop:  http://${DVWA_NODE_IP}:${JUICESHOP_NODEPORT}/"
echo "        Sin login inicial requerido — explora /#/score-board para retos"
echo
kubectl get pods -n "$SECURITY_NS"   -o wide
kubectl get pods -n "$VULNERABLE_NS" -o wide
echo
echo "    Triggers de prueba:"
echo "      # Falco — shell en container:"
echo "      kubectl exec -n monitoring -it \$(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o name | head -1) -- /bin/sh -c 'id; exit'"
echo "      # Suricata — petición a cada CMS desde el master:"
echo "      curl -s -o /dev/null -w 'DVWA       %{http_code}\n' http://${DVWA_NODE_IP}:${DVWA_NODEPORT}/login.php"
echo "      curl -s -o /dev/null -w 'WebGoat    %{http_code}\n' http://${DVWA_NODE_IP}:${WEBGOAT_NODEPORT}/WebGoat/login.mvc"
echo "      curl -s -o /dev/null -w 'Juice Shop %{http_code}\n' http://${DVWA_NODE_IP}:${JUICESHOP_NODEPORT}/"
echo
echo "    Queries LogQL en Grafana → Explore → Loki:"
echo "      (Promtail indexa con label corto 'app=', NO 'app.kubernetes.io/name')"
echo "      Falco:    {namespace=\"security\", app=\"falco\"}    | json | rule != \"\""
echo "      Suricata: {namespace=\"security\", app=\"suricata\"} | json | event_type = \"alert\""
