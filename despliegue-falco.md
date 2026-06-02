# Despliegue de Falco standalone

Runbook para desplegar Falco (runtime IDS via eBPF) sobre el cluster de
este proyecto. DaemonSet en worker1 + worker2 (master excluido), output
JSON a stdout consumido por Promtail → Loki → Grafana.

## Decisión arquitectónica — un solo chart, no la suite completa

`falcosecurity/` publica tres charts complementarios:

| Chart | Función | Lo desplegamos? |
|---|---|---|
| `falco` | Detector — DaemonSet con eBPF + ruleset | **Sí** |
| `falcosidekick` | Router HTTP de eventos a destinos externos (Slack, Loki, Elastic) | No — Promtail ya cubre la ruta a Loki vía stdout |
| `falco-exporter` | Traduce eventos a métricas Prometheus | No por ahora — futuro F4 si queremos métricas de tasa de eventos |

Solo desplegamos el primero. La pipeline final es:

```
syscall → eBPF probe → falco engine → ruleset match → JSON event → stdout
                                                                      ↓
                                       /var/log/pods/.../falco/0.log
                                                                      ↓
                                                                  Promtail
                                                                      ↓
                                                                    Loki
                                                                      ↓
                                                              Grafana Explore
```

## Requisitos previos

- Cluster k8s activo (kubespray instalado vía `setup-kubespray.sh`).
- Helm 4 instalado en master (Fase 1 de `setup-lab.sh`).
- Stack de monitoring corriendo: Loki + Promtail + Grafana
  (ejecutado `setup-lab.sh` previamente).
- Namespace `security` creado (`kubectl create namespace security`).
- Repo `falcosecurity` añadido a Helm
  (`helm repo add falcosecurity https://falcosecurity.github.io/charts`).
- Archivos versionados en el repo:
  - `values/falco.yaml`

---

## 1. Verificar precondiciones

```bash
ssh test-master

# Cluster vivo y nodos listos
kubectl get nodes
# Esperado: master, worker1, worker2 — STATUS Ready

# Namespace existe
kubectl get ns security
# Esperado: STATUS Active. Si no existe: kubectl create ns security

# Kernel >= 5.8 en los workers (modern_ebpf lo requiere)
ssh test-worker1 'uname -r'
ssh test-worker2 'uname -r'
# Esperado: 5.15.x-...-generic  (Ubuntu 22.04 default)

# Repos de Helm
helm repo list | grep falcosecurity
# Esperado: falcosecurity  https://falcosecurity.github.io/charts

# Versión del chart
helm search repo falcosecurity/falco
# Esperado: falcosecurity/falco  8.0.x  0.43.x  Falco
```

---

## 2. Render seco antes de instalar

```bash
# Validación A: el render no falla (catch errores de schema en values)
helm template falco falcosecurity/falco -f /vagrant/values/falco.yaml -n security \
  >/tmp/falco-render.yaml
echo "Líneas generadas: $(wc -l < /tmp/falco-render.yaml)"
# Esperado: ~500-800 líneas. Si falla, leer el error antes de instalar.

# Validación B: una sola imagen (Falco principal)
grep 'image:' /tmp/falco-render.yaml | sort -u
# Esperado:
#   image: docker.io/falcosecurity/falco-no-driver:0.43.x   (init container)
#   image: docker.io/falcosecurity/falco:0.43.x            (main container)
#   image: docker.io/falcosecurity/falcoctl:0.x.x          (sidecar de reglas)

# Validación C: cero ServiceMonitor (no hay Prometheus Operator)
grep -c 'kind: ServiceMonitor' /tmp/falco-render.yaml
# Esperado: 0

# Validación D: tolerations vacías
grep -A 1 'tolerations:' /tmp/falco-render.yaml | head -10
# Esperado: 'tolerations: []'  (sin overrides para control-plane)

# Validación E: driver modern_ebpf
grep -A 5 'engine:' /tmp/falco-render.yaml | head -10
# Esperado: kind: modern_ebpf
```

---

## 3. Instalar Falco

```bash
helm install falco falcosecurity/falco \
  --namespace security \
  -f /vagrant/values/falco.yaml \
  --wait --timeout 5m

kubectl get pods -n security -l app.kubernetes.io/name=falco -o wide
# Esperado:
#   falco-aaaaa   2/2   Running   0   <age>   worker1
#   falco-bbbbb   2/2   Running   0   <age>   worker2
# 2 pods (uno por worker), 2/2 containers (falco + falcoctl sidecar).
# Si aparece un tercer pod en master, las tolerations no se aplicaron.
```

---

## 4. Verificar el driver eBPF cargado

```bash
# El pod arranca un initContainer 'falco-driver-loader' que verifica/carga
# el probe eBPF. Si esto falla, el pod queda en CrashLoopBackOff.
kubectl logs -n security -l app.kubernetes.io/name=falco -c falco --tail=30 | head -50
# Esperado (entre otras líneas):
#   "Falco initialized with configuration files"
#   "Loading rules from file: /etc/falco/falco_rules.yaml"
#   "Starting health webserver with threadiness 2, listening on 0.0.0.0:8765"
# NO debe aparecer:
#   "ERROR: Driver not loaded"
#   "BPF probe loading failed"

# Verificar el endpoint de health
kubectl exec -n security <pod-falco> -c falco -- \
  curl -s http://localhost:8765/healthz
# Esperado: {"status": "ok"}
# (Falco 0.43 expone /healthz en 8765 por defecto)
```

---

## 5. Disparar una detección — el momento de la verdad

Lección del vault: la regla **"Terminal shell in container"** requiere
`proc.tty != 0`, lo que significa que un `kubectl exec` SIN `-t` no la
dispara. Hay que asignar TTY.

### 5a. Disparar desde un pod existente

```bash
# Cualquier pod del cluster sirve — usamos uno de monitoring
TARGET=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o name | head -1)

# CRÍTICO: -it (no solo -i). El -t es lo que asigna TTY.
kubectl exec -n monitoring -it "$TARGET" -- /bin/sh
# Dentro del shell:
#   $ id
#   $ exit
```

### 5b. Ver el evento en Falco

```bash
# Inmediatamente después de salir del shell
kubectl logs -n security -l app.kubernetes.io/name=falco -c falco --tail=50 \
  | grep -i 'terminal shell'
# Esperado (línea JSON):
# {"hostname":"...","output":"... A shell was spawned in a container ...",
#  "priority":"Notice","rule":"Terminal shell in container",
#  "tags":["T1059","container","mitre_execution","shell"]}
```

Si aparece esa línea, **la pipeline detector → log funciona**.

### 5c. Disparar otras reglas

| Regla | Cómo dispararla |
|---|---|
| Read sensitive file untrusted | `kubectl exec -it <pod> -- cat /etc/shadow` |
| Write below etc | `kubectl exec -it <pod> -- sh -c 'echo x > /etc/test'` |
| Run shell untrusted | `kubectl exec -it <pod> -- bash -c 'whoami'` |
| Modify binary dirs | `kubectl exec -it <pod> -- touch /usr/bin/evil` |

Cada una imprime un evento JSON distinto en `kubectl logs`.

---

## 6. Verificar que el evento llega a Loki

```bash
kubectl run -n monitoring loki-falco --rm -it --restart=Never \
  --image=curlimages/curl:latest -- \
  sh -c 'curl -s "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/labels"'
# Esperado: array de labels que incluye 'namespace','pod','container'

# Listar pods en el namespace 'security' que Promtail está siguiendo
kubectl run -n monitoring loki-falco --rm -it --restart=Never \
  --image=curlimages/curl:latest -- \
  sh -c 'curl -s "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/label/namespace/values"'
# Esperado: lista que incluye "security"
```

En Grafana → Explore → Loki:

```logql
{namespace="security"} |= "Terminal shell"
```

Esperado: las líneas JSON de los eventos disparados en paso 5. Round-trip
completo verificado.

---

## 7. Troubleshooting

### Pod en `CrashLoopBackOff` con `Driver not loaded`
El kernel del worker no soporta `modern_ebpf` (< 5.8) o el módulo
`bpf` no está habilitado. Verifica con `uname -r` y `lsmod | grep bpf`.
Fallback: cambiar `driver.kind` a `ebpf` (legacy probe — requiere
kernel-headers, más frágil) o `kmod` (módulo del kernel — peor).

### `Error: cannot patch "falco" with kind ...` al hacer `helm upgrade`
El chart de Falco usa CRDs (`Rules`, `Plugins`) que cambian entre
versiones mayores. Si saltas de 7.x a 8.x, hay que `helm uninstall`
+ borrar CRDs antes de reinstalar, no upgrade in-place.

### Eventos generados pero no aparecen en Loki
Verifica:
1. Promtail corre en el nodo donde se disparó la detección
   (`kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail -o wide`).
2. El stdout de Falco efectivamente sale en `kubectl logs`. Si sí,
   Promtail debería leerlo automáticamente — el namespace `security`
   no está excluido en `values/promtail.yaml`.

### Falco loggea pero ninguna regla se dispara
Lección del vault: las reglas tienen condiciones específicas. La de
"Terminal shell in container" requiere TTY (`proc.tty != 0`) — sin
`-t` en kubectl exec no se dispara. Lee la regla en
`/etc/falco/falco_rules.yaml` para entender la condición exacta.

### `falcoctl` sidecar en estado `Error` o `CrashLoopBackOff`
`falcoctl` descarga rulesets desde un OCI registry; si el cluster no
tiene salida a Internet, falla. Solución: poner `falcoctl.artifact.install.enabled: false`
y `falcoctl.artifact.follow.enabled: false` en values. Las reglas
built-in del chart (en el ConfigMap) siguen funcionando.

---

## Resumen en una pantalla

```bash
# master
kubectl create namespace security
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm install falco falcosecurity/falco -n security -f /vagrant/values/falco.yaml --wait

# Verificar pods
kubectl get pods -n security -o wide
# 2 pods Running 2/2 en worker1+worker2

# Disparar detección
GRAFANA_POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o name | head -1)
kubectl exec -n monitoring -it "$GRAFANA_POD" -- /bin/sh -c 'id; exit'

# Ver evento
kubectl logs -n security -l app.kubernetes.io/name=falco -c falco --tail=50 \
  | grep -i 'shell'
```

LogQL canónica de validación en Grafana:

```logql
{namespace="security"} | json | rule != ""
```
