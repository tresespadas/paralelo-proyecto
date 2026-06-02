# Despliegue de Grafana standalone

Runbook de comandos para desplegar Grafana standalone sobre el cluster
kubespray de este proyecto, con persistencia en hostPath en worker2.

## Requisitos previos
- Cluster k8s activo (3 nodos: `master`, `worker1`, `worker2`).
- Namespaces `vulnerable`, `monitoring`, `security` creados (fase 7 del `setup-kubespray.sh`).
- Archivos versionados en el repo:
  - `manifests/storage/grafana-pv.yaml`
  - `values/grafana.yaml`

---

## 1. Instalar Helm 4 en master

```bash
ssh test-master

cd ~
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
bash get_helm.sh

helm version
# version.BuildInfo{Version:"v4.1.4", ...}
```

El instalador hace `sudo install` del binario a `/usr/local/bin/helm`. Funciona
sin pedir password porque el usuario `master` tiene sudo sin contraseña.

---

## 2. Preparar el hostPath en worker2

```bash
ssh test-worker2

sudo mkdir -p /mnt/data/grafana
sudo chown 472:472 /mnt/data/grafana
ls -lnd /mnt/data/grafana
# drwxr-xr-x 2 472 472 4096 ... /mnt/data/grafana
```

UID 472 es el usuario `grafana` dentro de la imagen oficial. `fsGroup` no
recursiza en hostPath, por eso el pre-chown es obligatorio.

---

## 3. Llevar los manifests a master

Dos rutas según cómo tengas la sincronización. La carpeta `/vagrant` en las
VMs solo se actualiza en `vagrant up` o con `vagrant rsync` explícito.

**Opción A — carpeta compartida (si está actualizada):**
```bash
# En master
ls /vagrant/manifests/storage/grafana-pv.yaml
ls /vagrant/values/grafana.yaml
```

**Opción B — scp desde el host:**
```bash
# Desde el host (raíz del repo)
scp manifests/storage/grafana-pv.yaml test-master:~/grafana-pv.yaml
scp values/grafana.yaml             test-master:~/grafana-values.yaml
```

---

## 4. Aplicar el PV y el PVC

```bash
# En master
kubectl apply -f /vagrant/manifests/storage/grafana-pv.yaml
# o: kubectl apply -f ~/grafana-pv.yaml

kubectl get pv grafana-pv
# STATUS: Bound, CLAIM: monitoring/grafana-pvc

kubectl get pvc -n monitoring grafana-pvc
# STATUS: Bound, VOLUME: grafana-pv
```

El binding es estático gracias a `volumeName: grafana-pv` en el PVC.

---

## 5. Añadir el repo de Helm y actualizar el índice

```bash
# En master
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

---

## 6. Instalar el chart

```bash
# En master
helm install grafana grafana/grafana \
  --namespace monitoring \
  -f /vagrant/values/grafana.yaml
# (o -f ~/grafana-values.yaml)

kubectl get pods -n monitoring -w
# Ctrl+C cuando veas:
# grafana-xxxxxxxxxx-xxxxx   1/1   Running   0   30s
```

---

## 7. Verificar acceso

```bash
# En master
kubectl get svc -n monitoring grafana
# NAME     TYPE       PORT(S)        AGE
# grafana  NodePort   80:30711/TCP   ...
```

Acceso desde el host (cualquier IP de nodo sirve, kube-proxy reencamina al pod):

- `http://10.0.1.10:30711` (master)
- `http://10.0.1.11:30711` (worker1)
- `http://10.0.1.12:30711` (worker2)

Login inicial: `admin` / `admin`.

---

## 8. Check de persistencia

```bash
# En worker2
sudo ls /mnt/data/grafana/
# csv  grafana.db  pdf  plugins  png
```

`grafana.db` es la base de datos SQLite interna de Grafana — si está ahí, el
mount hostPath → PVC → pod funciona end-to-end.

---

## Troubleshooting — fallo inicial (documentado a propósito)

### Síntoma
```
kubectl get pods -n monitoring
NAME                      READY   STATUS               RESTARTS   AGE
grafana-xxx-xxx           0/1     Init:ErrImagePull    0          71s
```

### Diagnóstico
```bash
kubectl describe pod -n monitoring <pod-name>
```

En la sección `Events:` aparecía:
```
Failed to pull image "docker.io/library/busybox:1.31.1":
  dial tcp 172.64.66.1:443: i/o timeout
```

El init container `init-chown-data` del chart intenta pulear busybox para
hacer `chown -R 472:472 /var/lib/grafana`, y la conexión al CDN de blobs de
Docker Hub (Cloudflare R2) se colgaba.

### Fix
Añadir al `values/grafana.yaml`:
```yaml
initChownData:
  enabled: false
```

Es un fix limpio, no un workaround: ya habíamos hecho el chown a mano en el
paso 2, así que el init container era redundante.

### Reinstall
```bash
helm uninstall grafana -n monitoring
helm install   grafana grafana/grafana \
  --namespace monitoring \
  -f /vagrant/values/grafana.yaml
```

El PVC sobrevive al `uninstall` porque lo creamos nosotros fuera del release
(Helm no lo gestiona).

### Comandos de diagnóstico que conviene conocer
```bash
# En master — eventos ordenados por tiempo en el namespace
kubectl get events -n monitoring --sort-by='.lastTimestamp' | tail -20

# En el nodo donde corre el pod — listar imágenes ya pulleadas
sudo crictl images

# En el nodo — forzar un pull directo con containerd (descarta el kubelet)
sudo crictl pull docker.io/grafana/grafana:12.3.1
```

---

## Resumen en una pantalla

```bash
# master
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 && chmod 700 get_helm.sh && bash get_helm.sh

# worker2
sudo mkdir -p /mnt/data/grafana && sudo chown 472:472 /mnt/data/grafana

# master
kubectl apply -f /vagrant/manifests/storage/grafana-pv.yaml
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update
helm install grafana grafana/grafana -n monitoring -f /vagrant/values/grafana.yaml
kubectl get pods -n monitoring -w
```

Acceso: `http://10.0.1.12:30711` (admin / grafana!).
