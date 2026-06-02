# Despliegue de Prometheus standalone

Runbook de comandos para desplegar Prometheus standalone sobre el cluster
kubespray de este proyecto, con persistencia en hostPath en worker2 y con
un mini-lab de relabeling al final.

Scope del despliegue:
- `server` (TSDB + API + UI), anclado a worker2, NodePort 30090.
- `node-exporter` (DaemonSet, uno por nodo) para métricas del SO.
- `kube-state-metrics` para métricas sobre objetos de la API de k8s.
- `alertmanager` y `pushgateway` **desactivados** (no se usan en el lab).

## Requisitos previos
- Cluster k8s activo (3 nodos: `master`, `worker1`, `worker2`).
- Namespaces `vulnerable`, `monitoring`, `security` creados (fase 7 del `setup-kubespray.sh`).
- Helm 4 instalado en master (ver `despliegue-grafana.md` paso 1 si hiciera falta).
- Grafana standalone ya desplegado (mismo patrón hostPath+NodePort, `despliegue-grafana.md`).
- Archivos versionados en el repo:
  - `manifests/storage/prometheus-pv.yaml`
  - `values/prometheus.yaml`

---

## 1. Añadir el repo de Helm y verificar versión del chart

```bash
ssh test-master

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm search repo prometheus-community/prometheus --versions | head -5
# Ejemplo: prometheus-community/prometheus  29.2.1  v3.11.2
```

---

## 2. Descubrir los UIDs reales del chart

Antes de hacer `chown` en el hostPath, confirma el UID que el chart usa:

```bash
# En master
helm show values prometheus-community/prometheus | grep -A 5 -n 'securityContext'
```

Resultado esperado para el `server`:
```
runAsUser: 65534
runAsNonRoot: true
runAsGroup: 65534
fsGroup: 65534
```

UID **65534** = `nobody` en Linux. Es distinto del 1000:2000 del chart
`kube-prometheus-stack` — mismo proyecto upstream, distinto chart, distinto UID.

---

## 3. Preparar el hostPath en worker2

```bash
ssh test-worker2

sudo mkdir -p /mnt/data/prometheus
sudo chown 65534:65534 /mnt/data/prometheus
ls -lnd /mnt/data/prometheus
# drwxr-xr-x 2 65534 65534 4096 ... /mnt/data/prometheus
```

`fsGroup` no recursiza en hostPath — por eso el pre-chown manual es obligatorio,
igual que en Grafana.

---

## 4. Llevar los manifests a master

Dos rutas según cómo tengas la sincronización:

**Opción A — `/vagrant` vía rsync:**
```bash
# En el host
vagrant rsync test-master
# En master
ls /vagrant/manifests/storage/prometheus-pv.yaml
ls /vagrant/values/prometheus.yaml
```

**Opción B — `scp` directo:**
```bash
# En el host (raíz del repo)
scp manifests/storage/prometheus-pv.yaml test-master:~/prometheus-pv.yaml
scp values/prometheus.yaml               test-master:~/prometheus-values.yaml
```

---

## 5. Aplicar el PV y el PVC

```bash
# En master
kubectl apply -f /vagrant/manifests/storage/prometheus-pv.yaml
# o: kubectl apply -f ~/prometheus-pv.yaml

kubectl get pv prometheus-pv
# STATUS: Bound, CLAIM: monitoring/prometheus-pvc

kubectl get pvc -n monitoring prometheus-pvc
# STATUS: Bound, VOLUME: prometheus-pv
```

Binding estático gracias a `volumeName: prometheus-pv` en el PVC.

---

## 6. Instalar el chart

```bash
# En master
helm install prometheus prometheus-community/prometheus \
  --namespace monitoring \
  -f /vagrant/values/prometheus.yaml
# (o -f ~/prometheus-values.yaml)

kubectl get pods -n monitoring -w
# Esperar:
#   prometheus-server-*                           2/2 Running   (multi-container)
#   prometheus-kube-state-metrics-*               1/1 Running
#   prometheus-prometheus-node-exporter-*   x3    1/1 Running   (DaemonSet)
```

El pod `prometheus-server` tiene 2 containers: el server real + un sidecar
`configmap-reload` que recarga la config sin reiniciar el pod cuando cambia.
El `2/2` puede tardar ~30-60s en aparecer mientras hace el WAL replay inicial.

---

## 7. Verificar acceso a la UI

```bash
# En master
kubectl get svc -n monitoring prometheus-server
# NAME               TYPE       PORT(S)        AGE
# prometheus-server  NodePort   80:30090/TCP   ...
```

Acceso desde el host (cualquier IP de nodo sirve, kube-proxy reencamina):

- `http://10.0.1.10:30090` (master)
- `http://10.0.1.11:30090` (worker1)
- `http://10.0.1.12:30090` (worker2)

En la UI: **Status → Target Health** debería mostrar ~6 jobs, todos con
targets UP.

---

## 8. Check de persistencia

```bash
# En worker2
sudo ls /mnt/data/prometheus/
# chunks_head  queries.active  wal   (estructura del TSDB)
```

La TSDB de Prometheus se materializa en cuanto el pod empieza a scrapear. Si
las tres entradas están ahí, el mount hostPath → PVC → pod funciona
end-to-end.

---

## 9. Añadir Prometheus como datasource en Grafana

La parte bonita — usar el **DNS interno del cluster**, no el NodePort externo.

1. Abrir Grafana: `http://10.0.1.12:30711` → login (`admin`/contraseña).
2. **Connections → Data sources → Add new data source → Prometheus**.
3. Rellenar:
   - **Name**: `Prometheus`
   - **Prometheus server URL**: `http://prometheus-server.monitoring.svc.cluster.local`
4. **Save & test** → banner verde "Successfully queried the Prometheus API".

Verificación en Grafana → Explore → modo Code:

```promql
up
# Lista de todos los targets con su estado (1 = UP, 0 = DOWN)

100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))
# % CPU usado por nodo (query canónica)
```

---

## 10. Mini-lab: relabeling con `extraScrapeConfigs`

Opcional pero muy recomendable pedagógicamente. Añade un job adicional que
demuestra cómo construir labels sintéticos desde los metadatos del service
discovery.

### Concepto

El pipeline `relabel_configs` corre **antes** del scrape sobre los labels
meta (`__meta_kubernetes_*`) que inyecta el SD de k8s. Aquí inventamos un
label `node` legible a partir de `__meta_kubernetes_pod_node_name`.

### Edit en `values/prometheus.yaml`

Añadir al **nivel raíz** del archivo (NO bajo `server:` — importante, ver
troubleshooting):

```yaml
extraScrapeConfigs: |
  - job_name: node-exporter-clean
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names: [monitoring]
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        regex: prometheus-prometheus-node-exporter
        action: keep
      - source_labels: [__meta_kubernetes_pod_node_name]
        target_label: node
```

### Aplicar y verificar

```bash
# Desde el host
scp values/prometheus.yaml test-master:~/prometheus-values.yaml

# Verificar (sin aplicar) que el chart va a renderizar el bloque
helm template prometheus prometheus-community/prometheus \
  -f ~/prometheus-values.yaml \
  -n monitoring | grep -A 15 'node-exporter-clean'

# Aplicar
helm upgrade prometheus prometheus-community/prometheus \
  --namespace monitoring \
  -f ~/prometheus-values.yaml

kubectl get pods -n monitoring -w
# Esperar nuevo prometheus-server-* en 2/2 Running
```

Query de validación en Grafana:

```promql
up{job="node-exporter-clean"}
# Esperado: 3 filas (master, worker1, worker2) con value=1 y label node=X

100 * (1 - avg by (node) (rate(node_cpu_seconds_total{job="node-exporter-clean", mode="idle"}[5m])))
# Gráfico con 3 líneas de leyenda "master" / "worker1" / "worker2"
# (en vez de las IPs:puerto que da el label 'instance')
```

Nota: el chart default **ya inyecta `node`** en el job
`kubernetes-service-endpoints`. Este mini-lab es más valioso por entender
el mecanismo que por el label final — la misma técnica se aplicará cuando
metas exporters custom (DVWA, WebGoat, Suricata) donde el chart no traiga
reglas sensatas.

---

## Troubleshooting — fallos documentados a propósito

### `extraScrapeConfigs` bajo `server:` — fallo silencioso

**Síntoma**: `helm upgrade` reporta REVISION 2 deployed, pero el job custom
no aparece en Prometheus (`count by (job) (up)` no lo lista).

**Causa**: la clave `extraScrapeConfigs` vive en el **nivel raíz** de los
values, no bajo `server:`. Helm acepta cualquier clave sin warning; si está
mal ubicada, queda huérfana y el ConfigMap se renderiza sin el bloque.

**Verificación**:
```bash
helm show values prometheus-community/prometheus | grep -n extraScrapeConfigs
# Si la línea sale a columna 0 → es clave top-level.

kubectl get cm -n monitoring prometheus-server \
  -o jsonpath='{.data.prometheus\.yml}' | grep -c 'node-exporter-clean'
# 0 = el ConfigMap no tiene nuestro job; 1+ = sí lo tiene
```

**Defensa**: usar `helm template` antes de `helm upgrade`:
```bash
helm template prometheus prometheus-community/prometheus \
  -f ~/prometheus-values.yaml | grep -A 5 node-exporter-clean
```
Si no aparece → la ubicación del YAML está mal.

### Query PromQL devuelve "No data"

Diagnóstico "pelar la cebolla" — ir de lo simple a lo complejo:

```promql
up                                               # 1. ¿Hay targets?
count by (job) (up)                              # 2. ¿Existe mi job?
node_cpu_seconds_total{job="mi-job"}             # 3. ¿Produce métricas?
rate(node_cpu_seconds_total{job="mi-job"}[5m])   # 4. ¿Rate funciona?
```

La primera query que devuelve datos te dice exactamente qué capa rompe.

### `rate()` sin ventana → "parse error: unclosed left parenthesis"

```promql
# MAL
rate(node_cpu_seconds_total{mode="idle"}
# BIEN
rate(node_cpu_seconds_total{mode="idle"}[5m])
```

`rate()` necesita un **range vector** (con `[5m]`), no un instant vector.
Regla mnemotécnica: funciones `rate/increase/delta/*_over_time` → **siempre**
corchetes de ventana.

### `prometheus-pushgateway` vs `pushgateway` (nombre del subchart)

Para desactivar el pushgateway hay que usar el **nombre del subchart**:
```yaml
prometheus-pushgateway:
  enabled: false
```
No `pushgateway:` — esa clave se ignora silenciosamente, mismo problema que
`extraScrapeConfigs` mal ubicado.

---

## Resumen en una pantalla

```bash
# master
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# worker2
sudo mkdir -p /mnt/data/prometheus && sudo chown 65534:65534 /mnt/data/prometheus

# master
kubectl apply -f /vagrant/manifests/storage/prometheus-pv.yaml
helm install prometheus prometheus-community/prometheus \
  -n monitoring -f /vagrant/values/prometheus.yaml
kubectl get pods -n monitoring -w
```

Acceso Prometheus: `http://10.0.1.12:30090`
Datasource en Grafana: `http://prometheus-server.monitoring.svc.cluster.local`
