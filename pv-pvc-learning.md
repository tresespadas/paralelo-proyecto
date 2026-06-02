# PV/PVC en `proyecto/` — cómo y por qué

Guía de aprendizaje sobre cómo se implementó el almacenamiento persistente en el proyecto hermano `~/Work/proyecto/`. El objetivo es entender el **por qué** detrás de cada decisión, no solo el qué.

Referencias cruzadas:
- Manifiestos: `~/Work/proyecto/manifests/storage/`
- Decisiones arquitectónicas: `~/Work/proyecto/docs/architecture-decisions.md` (secciones "Persistent storage strategy")
- Notas del vault: `~/Documents/arch-lab-vault/proyecto/infra/04 Discos persistentes.md` y `.../seguridad/15 Fase 4 - Monitoring.md`

---

## 1. El problema que resuelven PV y PVC

Los pods en Kubernetes son efímeros: cuando un pod muere, su sistema de ficheros desaparece. Si Prometheus escribe métricas en `/prometheus/` dentro del contenedor y el pod se reinicia, pierde todo el histórico.

La tentación ingenua es usar `hostPath` directamente en el pod:
```yaml
volumes:
  - name: data
    hostPath:
      path: /mnt/data/prometheus
```

Esto funciona, pero acopla la aplicación a la infraestructura: el chart de Prometheus no sabe (ni debe saber) en qué ruta del host guardas los datos. **PV y PVC rompen ese acoplamiento con dos capas**:

- **PersistentVolume (PV)**: recurso del cluster que representa almacenamiento físico. Lo crea el admin. Dice "aquí hay 5 GiB en `/mnt/data/prometheus` del nodo worker2".
- **PersistentVolumeClaim (PVC)**: petición que hace el workload. Dice "necesito 5 GiB con modo `ReadWriteOnce`". Kubernetes empareja el PVC con un PV compatible (proceso llamado *binding*).

El chart solo referencia el PVC por nombre — no sabe si detrás hay un disco local, NFS, o un volumen en AWS EBS.

---

## 2. La pila completa en `proyecto/` (del disco físico al pod)

```
disks/worker2-data.qcow2   (archivo qcow2 en el host, sobrevive a vagrant destroy)
        ↓  attach-disks.sh → virsh attach-disk
/dev/vdb                   (disco dentro de la VM)
        ↓  mkfs.ext4 + mount + /etc/fstab con nofail
/mnt/data                  (punto de montaje dentro de la VM)
        ↓  mkdir /mnt/data/prometheus
/mnt/data/prometheus       (ruta que referencia el PV)
        ↓  PV: hostPath
PersistentVolume: prometheus-pv
        ↓  binding por volumeName + claimRef
PersistentVolumeClaim: storage-prometheus-server-0  (creado por el StatefulSet)
        ↓  spec.volumes.persistentVolumeClaim
Pod: prometheus-server-0   (monta el volumen en /prometheus dentro del contenedor)
```

Cada capa tiene un responsable distinto:

| Capa | Quién lo crea | Cuándo |
|---|---|---|
| qcow2 | `scripts/ensure-disks.sh` (trigger `before :up` en master) | Antes del arranque de las VMs |
| attach + mount | `scripts/attach-disks.sh` (trigger `after :up` en worker2) | Cuando todas las VMs están arriba |
| PV | `kubectl apply -f manifests/storage/*.yaml` | Tras instalar el cluster |
| PVC | Depende del patrón (ver sección 4) | En deploy del workload |

---

## 3. Provisioning estático vs dinámico

En la mayoría de clusters productivos encuentras **provisioning dinámico**: defines una `StorageClass` (por ejemplo, `gp3` en AWS) y cuando un PVC aparece, un *provisioner* crea el PV automáticamente.

En `proyecto/` se usa **provisioning estático**: los PVs se pre-crean a mano. La señal clave en todos los manifiestos es:

```yaml
spec:
  storageClassName: ""   # cadena vacía, no omitida
```

La distinción es sutil pero importante:

- **Sin el campo** (`storageClassName` ausente): Kubernetes usa la `StorageClass` marcada como `default` en el cluster. Si hubiera un provisioner dinámico configurado, crearía un PV nuevo ignorando el que tú pre-creaste.
- **Con cadena vacía** (`storageClassName: ""`): desactiva explícitamente el provisioning dinámico. Kubernetes solo hará bind con PVs que también tengan `storageClassName: ""`.

Al combinarlo con `volumeName` en el PVC, fuerzas un emparejamiento 1-a-1 explícito entre PVC y PV concretos.

---

## 4. Los dos patrones de binding usados

### Patrón A: PV + PVC declarados juntos

Usado en Grafana, Suricata, WebGoat y DVWA. Ejemplo `grafana-pv.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: grafana-pv
spec:
  capacity: { storage: 1Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath: { path: /mnt/data/grafana }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-pvc
  namespace: monitoring
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ""
  resources: { requests: { storage: 1Gi } }
  volumeName: grafana-pv    # bind explícito al PV
```

El chart de Grafana acepta `persistence.existingClaim: grafana-pvc` en sus values, así que basta con pasarle el nombre del PVC y todo encaja.

### Patrón B: solo PV, el StatefulSet crea el PVC

Usado en Prometheus y Loki. Ejemplo `prometheus-pv.yaml`:

```yaml
# PV only — PVC is managed by kube-prometheus-stack StatefulSet (binds via volumeName)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: prometheus-pv
spec:
  capacity: { storage: 5Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath: { path: /mnt/data/prometheus }
```

**Por qué no hay PVC aquí**: los StatefulSets usan `volumeClaimTemplates` para generar un PVC por réplica, con nombre determinista del estilo `<plantilla>-<statefulset>-<ordinal>` (por ejemplo, `storage-prometheus-server-0`). Si tú creas un PVC a mano, acabas con dos PVCs peleándose por el mismo PV.

El flujo real es:

```
1. kubectl apply -f prometheus-pv.yaml        → PV existe, estado: Available
2. helm install prometheus ...                → StatefulSet genera PVC autogenerado
3. kube-scheduler empareja PVC ↔ PV           → ambos pasan a Bound
```

El emparejamiento ocurre porque el PVC generado pide `5Gi`, `ReadWriteOnce`, `storageClassName: ""` — justo lo que ofrece el PV.

---

## 5. Por qué `Retain` y `nodeSelector` son inseparables con `hostPath`

### `persistentVolumeReclaimPolicy: Retain`

Tres políticas posibles:
- `Delete`: al borrar el PVC, el PV y los datos se borran. Peligroso en un lab donde haces `helm uninstall` a menudo.
- `Recycle`: deprecado.
- `Retain`: al borrar el PVC, el PV pasa a estado `Released` y **los datos siguen en disco**. Para reutilizarlo tienes que limpiar manualmente.

Elección de `proyecto/`: `Retain`. Razón literal del doc: "Data survives PVC deletion — prevents accidental data loss during Helm uninstall/reinstall".

### `nodeSelector` en el pod

`hostPath` es **node-local**: la ruta `/mnt/data/prometheus` solo existe en worker2, porque solo worker2 tiene el disco qcow2 montado allí. Si Kubernetes programa el pod de Prometheus en worker1, va a montar un directorio vacío (o que ni existe) y crashear.

Por eso los values de los charts fuerzan pinning:

```yaml
nodeSelector:
  kubernetes.io/hostname: worker2
```

Regla general: **si usas `hostPath` PV, siempre pin al nodo donde está el disco**. Sin excepciones.

Una alternativa más robusta sería `local` PVs con `nodeAffinity` en el PV mismo — Kubernetes entiende la afinidad y solo programa pods compatibles sin necesidad de `nodeSelector` en cada workload. `proyecto/` eligió `hostPath` por simplicidad, pagando el coste de configurar pinning en los charts.

---

## 6. Trampas aprendidas en el camino (de `15 Fase 4 - Monitoring.md`)

### Trampa 1: PVC pre-creado vs StatefulSet

En el primer intento se creó un PVC a mano para Prometheus (patrón A). El chart instaló su StatefulSet y generó su **propio** PVC. El PV quedó bound al PVC manual, el PVC autogenerado quedó `Pending` eternamente.

Solución (documentada en la nota):
1. Borrar el PVC pre-creado
2. Editar el PV para limpiar `claimRef` (el campo que le recuerda con qué PVC estaba bound)
3. Dejar que el chart cree su PVC y haga bind automáticamente

Por eso los manifiestos de Prometheus y Loki son **solo PV**: evitan esta trampa de raíz.

### Trampa 2: permisos de uid/gid con `hostPath`

Los drivers CSI manejan `fsGroup` automáticamente: si el pod declara `securityContext.fsGroup: 2000`, el volumen se chown-ea al montarse. **`hostPath` no hace esto.** Mantiene los permisos del directorio tal y como están en el host.

Síntomas encontrados:
- Prometheus (corre como uid 1000, gid 2000): `permission denied` en `/prometheus/queries.active`
- Loki (corre como uid 10001): `mkdir /var/loki/rules: permission denied`

Solución manual, ejecutada una vez en la VM:
```bash
sudo chown -R 1000:2000 /mnt/data/prometheus
sudo chown -R 10001:10001 /mnt/data/loki
```

Moraleja: con `hostPath` te conviertes tú en el responsable de los permisos del directorio en el host, no el operador.

---

## 7. Estados del ciclo de vida de un PV

Útil para depurar con `kubectl get pv`:

| Estado | Significado |
|---|---|
| `Available` | PV creado, sin bind a ningún PVC. Esperando match. |
| `Bound` | Emparejado con un PVC. Uso normal. |
| `Released` | El PVC fue borrado pero `reclaimPolicy: Retain` mantiene el PV. Los datos siguen en disco, pero el PV **no volverá a hacer bind** hasta que limpies `spec.claimRef` con `kubectl edit pv <nombre>`. |
| `Failed` | Error al reciclar o borrar automáticamente. |

Transiciones relevantes:

```
Available  → (aparece PVC compatible)   → Bound
Bound      → (kubectl delete pvc)       → Released   (con Retain)
Released   → (kubectl edit pv: borrar claimRef) → Available
```

---

## 8. Mini-laboratorio hands-on

Para ver los estados de primera mano en tu cluster `paralelo-proyecto` (cuando lo tengas levantado):

### Ejercicio 1: provisioning estático básico

```bash
# En test-master, crear un PV manual
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: demo-pv
spec:
  capacity: { storage: 100Mi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath: { path: /tmp/demo-pv }
EOF

kubectl get pv demo-pv
# STATUS: Available
```

### Ejercicio 2: bind con PVC explícito

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ""
  resources: { requests: { storage: 100Mi } }
  volumeName: demo-pv
EOF

kubectl get pv demo-pv
# STATUS: Bound
kubectl get pvc demo-pvc
# STATUS: Bound
```

### Ejercicio 3: ver el efecto de `Retain`

```bash
kubectl delete pvc demo-pvc

kubectl get pv demo-pv
# STATUS: Released   ← no se borró, los datos están intactos
```

### Ejercicio 4: reciclado manual

```bash
kubectl edit pv demo-pv
# Borrar todo el bloque spec.claimRef y guardar

kubectl get pv demo-pv
# STATUS: Available   ← reutilizable de nuevo
```

### Ejercicio 5: provocar la trampa del pinning

```bash
# Crear un Pod sin nodeSelector que use el PVC, y ver dónde lo programa.
# Si cae en un nodo que no tiene /tmp/demo-pv, el pod crashea o queda en
# ContainerCreating. Añade nodeSelector y observa el cambio.
```

---

## 9. Resumen de decisiones de `proyecto/` en una tabla

| Decisión | Valor elegido | Alternativa descartada | Razón |
|---|---|---|---|
| Tipo de PV | `hostPath` | NFS, Longhorn, CSI | Simplicidad en lab, sin infraestructura extra |
| Provisioning | Estático (`storageClassName: ""`) | Dinámico con StorageClass | Control explícito, un PV por servicio |
| Reclaim policy | `Retain` | `Delete` | Sobrevive a `helm uninstall` |
| Pinning | `nodeSelector` en el chart | `nodeAffinity` en `local` PV | Más simple, menos correcto |
| Binding con StatefulSets | Solo PV, sin PVC manual | PV + PVC manuales | Evita conflicto con `volumeClaimTemplates` |
| Binding con Deployments | PV + PVC manuales | Solo PV | Los charts esperan `existingClaim` |
| Backing storage | qcow2 fuera de vagrant-libvirt | Disco gestionado por Vagrant | Sobrevive a `vagrant destroy` |

---

## Siguiente paso sugerido

Cuando tengas el cluster de `paralelo-proyecto` operativo, replica el ejercicio de la sección 8 y luego intenta migrar **un solo servicio** (por ejemplo, un Grafana minimal) de la configuración del proyecto original. Vas a tropezar con la trampa de permisos o con el pinning — es justo el momento de consolidar lo aprendido.
