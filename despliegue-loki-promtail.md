# Despliegue de Loki + Promtail standalone

Runbook para desplegar Loki (SingleBinary) + Promtail (DaemonSet) sobre el
cluster de este proyecto. Persistencia hostPath en worker2 para Loki;
Promtail corre solo en worker1+worker2 (master excluido).

## Estado del chart — deuda técnica conocida

`grafana/promtail` está marcado como **deprecated** por Grafana Labs en
favor de `grafana/alloy` (agente unificado de logs+métricas+traces). La
imagen sigue manteniéndose, los pods funcionan estable, y los conceptos
(DaemonSet + tail logs + push HTTP a Loki) son idénticos a los de Alloy.
Se decide instalar Promtail conscientemente porque (a) es lo que está
en `~/Work/proyecto/`, (b) el aprendizaje transfiere, (c) la migración
futura será de sintaxis, no de modelo. Plan de migración: explorar
`grafana/alloy`, sustituir values en River, mantener Loki igual.

## Requisitos previos
- Cluster k8s activo con namespaces `vulnerable`, `monitoring`, `security`.
- Helm 4 instalado en master (Fase 1 de `setup-lab.sh`).
- Repo `grafana` añadido a Helm (`helm repo add grafana https://grafana.github.io/helm-charts`).
- Archivos versionados en el repo:
  - `manifests/storage/loki-pv.yaml`
  - `values/loki.yaml`
  - `values/promtail.yaml`

---

## 1. Preparar el hostPath de Loki en worker2

```bash
ssh test-worker2

sudo mkdir -p /mnt/data/loki
sudo chown 10001:10001 /mnt/data/loki
ls -lnd /mnt/data/loki
# drwxr-xr-x 2 10001 10001 ...
```

UID 10001 es el `runAsUser` del podSecurityContext del chart de Loki.
Lo confirmas con:
```bash
helm show values grafana/loki | grep -B 2 -A 3 'runAsUser'
```

Promtail **NO necesita pre-chown** — su positions file vive en hostPath
del nodo (`/run/promtail/positions.yaml`), creado por el propio pod.

---

## 2. Aplicar el PV de Loki

A diferencia de Grafana y Prometheus (PV+PVC en el mismo archivo), Loki
SOLO declara el PV. El PVC lo genera automáticamente el StatefulSet vía
`volumeClaimTemplates` con nombre `storage-loki-0`. El binding ocurre
por **matching de capacity + accessModes + storageClassName** (no por
`volumeName` explícito).

```bash
ssh test-master

kubectl apply -f /vagrant/manifests/storage/loki-pv.yaml

kubectl get pv loki-pv
# STATUS: Available  (todavía no hay PVC; lo creará el chart al instalar)
```

---

## 3. Render seco antes de instalar Loki

```bash
# Validación A: una sola imagen
helm template loki grafana/loki -f /vagrant/values/loki.yaml -n monitoring \
  | grep 'image:' | sort -u
# Esperado: docker.io/grafana/loki:3.6.7

# Validación B: cero ServiceMonitor (no hay Prometheus Operator)
helm template loki grafana/loki -f /vagrant/values/loki.yaml -n monitoring \
  | grep -c 'kind: ServiceMonitor'
# Esperado: 0

# Validación C: solo un container en el StatefulSet
helm template loki grafana/loki -f /vagrant/values/loki.yaml -n monitoring \
  | awk '/^      containers:/{f=1;next} f && /^      [a-zA-Z]/{f=0} f' \
  | grep '^        - name:'
# Esperado: 1 línea: '- name: loki'  (sin sidecar 'loki-sc-rules')
```

Si alguna falla, no instalar — diagnosticar el values primero.

---

## 4. Instalar Loki

```bash
helm install loki grafana/loki \
  --namespace monitoring \
  -f /vagrant/values/loki.yaml

kubectl get pods -n monitoring -l app.kubernetes.io/name=loki -w
# Esperar:
#   loki-0   1/1   Running   0   <age>
# Tarda más que Grafana/Prometheus porque el StatefulSet:
#   1. Crea el PVC storage-loki-0
#   2. Espera al binding con loki-pv (matching por capacity+SC)
#   3. Loki hace WAL replay y inicializa /var/loki
```

Verificación del binding:
```bash
kubectl get pvc -n monitoring storage-loki-0
# STATUS: Bound, VOLUME: loki-pv

kubectl get pv loki-pv
# STATUS: Bound, CLAIM: monitoring/storage-loki-0
```

---

## 5. Verificar Loki vivo (sin entrar al pod)

La imagen de Loki 3.x es distroless — no tiene `wget` ni `curl` ni shell.
Para diagnosticar se usa un pod efímero:

```bash
kubectl run -n monitoring loki-check --rm -it --restart=Never \
  --image=curlimages/curl:latest -- \
  sh -c 'curl -s http://loki.monitoring.svc.cluster.local:3100/ready && echo'
# Esperado: 'ready'

kubectl run -n monitoring loki-labels --rm -it --restart=Never \
  --image=curlimages/curl:latest -- \
  curl -s 'http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/labels'
# Esperado: {"status":"success","data":[]}
# Array vacío es CORRECTO — Loki está vivo pero nadie le envía aún.
```

---

## 6. Render seco antes de instalar Promtail

```bash
# Validación A: imagen + WARN de deprecated (esperado)
helm template promtail grafana/promtail -f /vagrant/values/promtail.yaml -n monitoring \
  | grep 'image:' | sort -u
# Esperado: docker.io/grafana/promtail:3.5.1
#           level=WARN msg="this chart is deprecated"   ← esperado, decisión consciente

# Validación B: sin ServiceMonitor
helm template promtail grafana/promtail -f /vagrant/values/promtail.yaml -n monitoring \
  | grep -c 'kind: ServiceMonitor'
# Esperado: 0

# Validación C: URL apunta a Loki interno
helm template promtail grafana/promtail -f /vagrant/values/promtail.yaml -n monitoring \
  | grep -A 1 'clients:' | head -5
# Esperado: url: http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push
#           NO loki-gateway (default del chart, que no existe en nuestro setup)

# Validación D: tolerations vacías (no schedulea en master)
helm template promtail grafana/promtail -f /vagrant/values/promtail.yaml -n monitoring \
  | grep -A 2 '^      tolerations:' | head -5
# Esperado: tolerations: []
```

---

## 7. Instalar Promtail

```bash
helm install promtail grafana/promtail \
  --namespace monitoring \
  -f /vagrant/values/promtail.yaml

kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail -o wide
# Esperado:
#   promtail-aaaaa   1/1   Running   0   <age>   worker1
#   promtail-bbbbb   1/1   Running   0   <age>   worker2
# Exactamente 2 pods. Si aparece uno en master, las tolerations no
# se aplicaron — uninstall + reinstall + verificar values.
```

---

## 8. Verificar la tubería end-to-end

### 8a. Promtail no llora

```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail --tail=30 | head -40
# Esperado: 'Seeked /var/log/pods/.../...log offset=...'
# NO debe aparecer 'connection refused' ni 'no such host'.
```

### 8b. Loki recibe logs

```bash
kubectl run -n monitoring loki-labels --rm -it --restart=Never \
  --image=curlimages/curl:latest -- \
  curl -s 'http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/labels'
# Esperado:
# {"status":"success","data":["container","filename","job","namespace","node","pod","stream"]}
# Comparar con el array vacío del paso 5 — ahora hay labels reales.

kubectl run -n monitoring loki-ns --rm -it --restart=Never \
  --image=curlimages/curl:latest -- \
  curl -s 'http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/label/namespace/values'
# Esperado: ["default","kube-system","monitoring","security","vulnerable"]
```

### 8c. Round-trip pedagógico — generar log y verlo en Grafana

```bash
kubectl run -n default echo-test --restart=Never --image=busybox -- \
  sh -c 'for i in $(seq 1 5); do echo "TEST_TAG hello $i"; sleep 2; done'
sleep 15
kubectl delete pod -n default echo-test
```

En Grafana → Explore → Loki:
```logql
{pod="echo-test"} |= "TEST_TAG"
```
Esperado: 5 líneas. Si aparecen, la cadena completa funciona:
pod stdout → containerd → /var/log/pods → Promtail → push HTTP → Loki TSDB
→ query LogQL desde Grafana → tu navegador.

---

## 9. Datasource Loki en Grafana

Si has desplegado Grafana con la sección `datasources` en
`values/grafana.yaml` (parte de la automatización), ya está cableado
automáticamente — verás "Loki" en `Connections → Data sources` con
el badge `Provisioned`.

Si lo desplegaste ANTES de la migración a provisioning (instalación
manual primera vez), añádelo por UI:
- **Connections → Data sources → Add new → Loki**
- **URL**: `http://loki.monitoring.svc.cluster.local:3100`
- **Save & test** → "Data source successfully connected"

---

## Troubleshooting

### `STATUS: Pending` en `storage-loki-0`
El PVC autogenerado no encontró PV compatible. Causas:
- PV en `Released` (de un install anterior): `kubectl patch pv loki-pv -p '{"spec":{"claimRef":null}}'`
- Capacity mismatch entre PV y values (ambos deben ser 5Gi).
- `storageClassName` distinto en PV (`""`) y values (`""`).

### Promtail crashloop con `connection refused`
La URL de Loki está mal. El default del chart (`loki-gateway`) no existe
en nuestro setup porque desactivamos `gateway.enabled` en `values/loki.yaml`.
Override obligatorio en `values/promtail.yaml`:
```yaml
config:
  clients:
    - url: http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push
```

### Promtail aparece en master
Default del chart trae tolerations para `node-role.kubernetes.io/master`
y `control-plane`. Override en `values/promtail.yaml`:
```yaml
tolerations: []
```

### `cannot exec` con wget/curl en pod de Loki
Imagen distroless — sin shell ni binarios. Diagnóstico vía pod efímero
(`kubectl run --rm -it --image=curlimages/curl ...`) o `kubectl port-forward`.

### Sidecar `loki-sc-rules` aparece en el render
El default del chart activa el sidecar kiwigrid para vigilar ConfigMaps
con label `loki_rule`. No usamos rules, lo apagamos en `values/loki.yaml`:
```yaml
sidecar:
  rules:
    enabled: false
```

---

## Resumen en una pantalla

```bash
# worker2
sudo mkdir -p /mnt/data/loki && sudo chown 10001:10001 /mnt/data/loki

# master
kubectl apply -f /vagrant/manifests/storage/loki-pv.yaml
helm install loki     grafana/loki     -n monitoring -f /vagrant/values/loki.yaml --wait
helm install promtail grafana/promtail -n monitoring -f /vagrant/values/promtail.yaml --wait

# Verificación 1: Loki responde
kubectl run -n monitoring c --rm -it --restart=Never --image=curlimages/curl:latest -- \
  curl -s http://loki.monitoring.svc.cluster.local:3100/ready
# 'ready'

# Verificación 2: Promtail solo en workers
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail -o wide
# 2 pods en worker1 + worker2

# Verificación 3: labels en Loki
kubectl run -n monitoring c --rm -it --restart=Never --image=curlimages/curl:latest -- \
  curl -s 'http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/labels'
# array no vacío con 'namespace','pod','container','node',...
```

LogQL canónica de validación:
```logql
{namespace="monitoring"}
```
