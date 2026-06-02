# Despliegue de Suricata + DVWA

Runbook para desplegar el IDS de red (Suricata) y un objetivo vulnerable
(DVWA) sobre el cluster de este proyecto. Suricata como DaemonSet con
`hostNetwork` en worker1, DVWA como Deployment en worker1 con MySQL
embebido y persistencia.

## Decisión arquitectónica — un solo nodo víctima + IDS

Suricata captura tráfico de la interfaz física del nodo, no del cluster
entero. Por eso pinneamos AMBOS componentes a worker1:

```
                    ┌──────────────────┐
  Kali (futuro)     │  worker1         │
  ─────────────────►│  eth0 (10.0.1.11)│
  HTTP a :30430     │   │              │
                    │   ├─► Suricata   │  (af-packet, eve.json)
                    │   │              │
                    │   └─► DVWA       │  (NodePort 30430 → Apache:80)
                    └──────────────────┘
```

Si DVWA viviera en worker2, Suricata en worker1 vería el tráfico solo
encapsulado por Flannel (VXLAN UDP:8472), no los paquetes HTTP en claro
— y el ruleset ET Open NO mira dentro del overlay.

## Decisión arquitectónica — Suricata sin PV, DVWA con PV

| Componente | Estado persistente | Decisión |
|---|---|---|
| Suricata | Reglas ET Open compiladas | `emptyDir` — el initContainer las re-descarga (~30s, vale la pena por simplicidad) |
| Suricata | `eve.json`, `fast.log` | `emptyDir` — los eventos ya van a Loki vía sidecar tail |
| DVWA | MySQL `/var/lib/mysql` | PV/PVC — sin esto, perderías el setup de la BD en cada restart |

## Decisión arquitectónica — sidecar tail vs Promtail hostPath

Suricata escribe a archivo (no stdout). Promtail solo recoge stdout de
pods. Tres opciones evaluadas:

| Opción | Cómo | Trade-off |
|---|---|---|
| **A — Sidecar tail** ✓ | Container auxiliar `tail -F eve.json` → stdout | K8s-idiomático, no toca Promtail, sin acoplamientos |
| B — Promtail hostPath scrape | Mount `/mnt/data/suricata` en Promtail + extra scrape | Acopla `values/promtail.yaml` a Suricata |
| C — Suricata a stderr | Reconfigurar Suricata sin `eve-log` | Pierdes el JSON estructurado |

Elegimos A. El sidecar es `busybox:1.36` (~5 MB RAM), `readOnly` sobre los
logs, sin capabilities — defensa en profundidad: un compromiso del sidecar
no puede manipular logs ni capturar tráfico.

## Requisitos previos

- Cluster k8s activo (kubespray instalado vía `setup-kubespray.sh`).
- Stack de monitoring corriendo (`setup-lab.sh` ejecutado): Loki + Promtail + Grafana.
- Falco ya desplegado (`despliegue-falco.md`).
- Helm 4 en master.
- Archivos versionados en el repo:
  - `charts/suricata/` (chart custom)
  - `charts/dvwa/` (chart custom)
  - `values/suricata.yaml`, `values/dvwa.yaml`
  - `manifests/storage/dvwa-pv.yaml`

---

## 1. Verificar precondiciones

```bash
ssh test-master

# Cluster vivo
kubectl get nodes

# Promtail Ready en al menos worker1
kubectl get ds -n monitoring promtail
# Esperado: DESIRED >= READY >= 1

# Confirmar interfaz de worker1
ssh worker1@10.0.1.11 'ip -br addr show eth0'
# Esperado: eth0  UP  10.0.1.11/24 ...
```

---

## 2. Render seco (validación de los charts custom)

```bash
helm template suricata /vagrant/charts/suricata -f /vagrant/values/suricata.yaml \
  -n security >/tmp/suricata-render.yaml
echo "Líneas: $(wc -l < /tmp/suricata-render.yaml)"
# Esperado: ~150-200 líneas. Si falla, revisa la sintaxis Go-template
# (con líneas y errores claros — Helm es bueno señalando dónde).

helm template dvwa /vagrant/charts/dvwa -f /vagrant/values/dvwa.yaml \
  -n vulnerable >/tmp/dvwa-render.yaml
echo "Líneas: $(wc -l < /tmp/dvwa-render.yaml)"
# Esperado: ~80-100 líneas.

# Validación A — Suricata: nodeSelector worker1
grep -A 1 'nodeSelector:' /tmp/suricata-render.yaml
# Esperado: kubernetes.io/hostname: test-worker1

# Validación B — Suricata: hostNetwork true
grep 'hostNetwork:' /tmp/suricata-render.yaml
# Esperado: hostNetwork: true

# Validación C — Suricata: 3 capabilities
grep -A 4 'capabilities:' /tmp/suricata-render.yaml | head -10
# Esperado: NET_ADMIN, NET_RAW, SYS_NICE en el container 'suricata',
# y 'drop: [ALL]' en el sidecar 'log-tail'

# Validación D — DVWA: NodePort 30430
grep 'nodePort:' /tmp/dvwa-render.yaml
# Esperado: nodePort: 30430

# Validación E — DVWA: PVC referenciado
grep -A 1 'claimName:' /tmp/dvwa-render.yaml
# Esperado: claimName: dvwa-pvc
```

---

## 3. Preparar hostPath para DVWA en worker1

```bash
ssh worker1@10.0.1.11 'sudo mkdir -p /mnt/data/dvwa && sudo chown 0:0 /mnt/data/dvwa'
```

DVWA corre como root (la imagen `vulnerables/web-dvwa` no tiene `USER`
en el Dockerfile). Por eso `chown 0:0` — coherente con el patrón del
resto del lab aunque sea no-op aquí.

---

## 4. Aplicar PV/PVC para DVWA

```bash
kubectl apply -f /vagrant/manifests/storage/dvwa-pv.yaml

kubectl get pv dvwa-pv
# Esperado: STATUS Bound (a vulnerable/dvwa-pvc)
kubectl get pvc -n vulnerable dvwa-pvc
# Esperado: STATUS Bound, VOLUME dvwa-pv, CAPACITY 2Gi
```

Si el PVC queda `Pending`: revisa que el PV tenga `storageClassName: ""`
y `volumeName` matching. La trampa típica: olvidar `storageClassName: ""`
(no `null`, no ausente — string vacío) hace que el scheduler busque
provisioner dinámico y se quede en Pending para siempre.

---

## 5. Instalar Suricata

```bash
helm upgrade --install suricata /vagrant/charts/suricata \
  --namespace security \
  -f /vagrant/values/suricata.yaml \
  --wait --timeout 5m

kubectl get pods -n security -l app.kubernetes.io/name=suricata -o wide
# Esperado:
#   suricata-XXXXX   2/2   Running   0   <age>   worker1
# 2/2 = container 'suricata' + sidecar 'log-tail'.
# Solo en worker1 (nodeSelector).
```

### Verificar que Suricata captura

```bash
SURICATA_POD=$(kubectl get pod -n security -l app.kubernetes.io/name=suricata -o name | head -1)

# Logs del initContainer — debe haberse ejecutado y exited
kubectl logs -n security "$SURICATA_POD" -c rules-update --tail=20
# Esperado: líneas como "Loaded XXX rules" y "Wrote /var/lib/suricata/rules/suricata.rules"

# Logs del container principal — Suricata arrancando
kubectl logs -n security "$SURICATA_POD" -c suricata --tail=20
# Esperado: "All AFP threads are running" y "engine started"
# NO debe aparecer: "Capabilities check failed" — significa que las
# capabilities NET_ADMIN/NET_RAW no llegaron al container.

# Logs del sidecar — tail esperando o ya leyendo
kubectl logs -n security "$SURICATA_POD" -c log-tail --tail=5
# Esperado: o "[log-tail] esperando..." (si Suricata no ha escrito aún)
# o líneas JSON de eve.json (event_type=stats, event_type=flow, etc.)
```

---

## 6. Instalar DVWA

```bash
helm upgrade --install dvwa /vagrant/charts/dvwa \
  --namespace vulnerable \
  -f /vagrant/values/dvwa.yaml \
  --wait --timeout 5m

kubectl get pods -n vulnerable -o wide
# Esperado: dvwa-XXX   1/1   Running   0   <age>   worker1
```

### Setup inicial de la BD

DVWA arranca con la BD vacía. Hay que inicializarla MANUALMENTE vía web:

```bash
# Desde el host (o desde el master con curl):
curl -sI http://10.0.1.11:30430/login.php
# Esperado: HTTP/1.1 200 OK
```

Luego en navegador:
1. `http://10.0.1.11:30430/setup.php`
2. Click en **"Create / Reset Database"**
3. Login con `admin` / `password`

Una vez hecho el setup, los datos viven en el PVC y sobreviven a
restarts del pod (gracias al `volumeName: dvwa-pv` con hostPath en
`/mnt/data/dvwa`).

---

## 7. Validar Suricata captura tráfico contra DVWA

```bash
# Genera tráfico HTTP a DVWA desde el master (o cualquier máquina del
# 10.0.1.0/24). Suricata debería ver estos paquetes en eth0 de worker1.
for i in $(seq 1 5); do
  curl -s -o /dev/null http://10.0.1.11:30430/login.php
done

# Ver el último flow HTTP en eve.json
SURICATA_POD=$(kubectl get pod -n security -l app.kubernetes.io/name=suricata -o name | head -1)
kubectl logs -n security "$SURICATA_POD" -c log-tail --tail=50 | grep '"event_type":"http"' | tail -3
# Esperado: líneas JSON con method=GET, url=/login.php, src/dst IPs reales del nodo
```

Si NO aparecen eventos `http`, Suricata está vivo pero no captura. Causas:
- Interfaz incorrecta (verifica `ip -br addr show` en worker1 — debe ser `eth0`)
- Capability `NET_ADMIN` no se aplicó (revisa el manifest del pod con
  `kubectl get pod -n security $SURICATA_POD -o yaml | grep -A 5 capabilities`)
- ET Open no cargó reglas HTTP (verifica `kubectl logs ... -c rules-update`)

---

## 8. Validar la pipeline a Loki

En Grafana → Explore → Loki:

```logql
# Todos los eventos de Suricata
{namespace="security", app_kubernetes_io_name="suricata"} | json

# Solo alertas (no flow/http/dns/stats)
{namespace="security", app_kubernetes_io_name="suricata"} | json | event_type = "alert"

# Top src_ip de tráfico HTTP (útil cuando llegue Kali)
sum by (src_ip) (count_over_time({namespace="security", app_kubernetes_io_name="suricata"} | json | event_type = "http" [5m]))
```

---

## 9. Troubleshooting

### Suricata pod en `Init:Error` o `Init:CrashLoopBackOff`
El initContainer `rules-update` falló. Causas típicas:
- Sin internet en worker1 (NAT roto): `ssh worker1 'curl -I https://rules.emergingthreats.net/'`
- DNS roto: `ssh worker1 'nslookup rules.emergingthreats.net'`
Solución: arreglar conectividad y `kubectl delete pod` para forzar reinicio.

### Suricata pod Running pero `eve.json` vacío
El proceso arrancó pero no captura. Verificar:
```bash
kubectl exec -n security $SURICATA_POD -c suricata -- \
  cat /etc/suricata/suricata.yaml | grep interface
# Debe mostrar: interface: eth0

kubectl exec -n security $SURICATA_POD -c suricata -- \
  ip -br addr show eth0
# Debe mostrar la IP del nodo (10.0.1.11), NO "Device not found".
# Si no la muestra, hostNetwork no se aplicó.
```

### DVWA pod en `Pending` con `pod has unbound immediate PersistentVolumeClaims`
El PVC no encuentra el PV. Causas:
- PV no aplicado (`kubectl get pv dvwa-pv` debe existir y estar Available o Bound)
- `storageClassName` no matcheando (ambos deben ser `""`)
- `accessModes` no compatibles (PVC pide RWO, PV ofrece RWO — debe coincidir)

### DVWA Running pero `/setup.php` da 500
La carpeta `/var/lib/mysql` no es escribible. Verifica permisos en worker1:
```bash
ssh worker1 'ls -ld /mnt/data/dvwa'
# Esperado: drwxr-xr-x ... root root ...
```

### Suricata sin eventos a Loki, aunque eve.json sí tiene contenido
El sidecar `log-tail` no está leyendo, o Promtail excluye el namespace.
Verificar:
```bash
# El sidecar está vivo y emite a stdout
kubectl logs -n security $SURICATA_POD -c log-tail --tail=5
# Promtail está scraping ese pod (busca el path en su config)
kubectl exec -n monitoring -l app.kubernetes.io/name=promtail -c promtail -- \
  cat /etc/promtail/promtail.yaml | grep -A 3 namespace
```

---

## Resumen en una pantalla

```bash
# master
kubectl create namespace security    --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace vulnerable  --dry-run=client -o yaml | kubectl apply -f -

ssh worker1 'sudo mkdir -p /mnt/data/dvwa && sudo chown 0:0 /mnt/data/dvwa'
kubectl apply -f /vagrant/manifests/storage/dvwa-pv.yaml

helm upgrade --install suricata /vagrant/charts/suricata \
  -n security -f /vagrant/values/suricata.yaml --wait

helm upgrade --install dvwa /vagrant/charts/dvwa \
  -n vulnerable -f /vagrant/values/dvwa.yaml --wait

# Setup inicial DVWA: visitar http://10.0.1.11:30430/setup.php → Create Database
```

LogQL canónica de validación en Grafana:

```logql
{namespace="security", app_kubernetes_io_name="suricata"} | json | event_type = "alert"
```
