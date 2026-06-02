● Let me walk through attach-disks.sh block by block. I'll flag the parts that are non-obvious and the ones you'll have to adapt for your test-* naming.

  ★ Insight ─────────────────────────────────────
  - Two execution contexts in one script: the outer commands (lines 1-27) run on the host (your Arch machine) because only the host can talk to libvirt. The heredoc (lines 29-67) runs inside the guest VM over SSH. Confusing these two is the single biggest trap when
  writing provisioning scripts — sudo inside the heredoc means sudo in the VM, not on your laptop.
  - The whole script is idempotent by design: every destructive action is guarded by a "does this already exist?" check. That's what lets vagrant up re-run triggers on an already-provisioned cluster without breaking anything. Idempotence is the core property that
  separates a provisioning script from an install script.
  - --persistent changes everything: without it, attach-disk only affects the running VM — a reboot loses the attachment. With it, the XML definition of the domain gets updated, so libvirt re-attaches on every future boot. This is why the script doesn't need to re-run
  after vagrant halt + vagrant up.
  ─────────────────────────────────────────────────

  Block 1 — setup (lines 1-6)

  VIRSH="virsh -c qemu:///system"
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  PROJECT_DIR="$SCRIPT_DIR/.."
  DISK_DIR="$PROJECT_DIR/disks"

  - qemu:///system is the system-level libvirt connection (runs as root, managed by libvirtd). The alternative is qemu:///session (per-user, lightweight). Vagrant-libvirt uses the system connection by default, so your script has to match — otherwise you'd be looking at
  a different set of VMs.
  - SCRIPT_DIR / PROJECT_DIR use the cd + pwd trick to get an absolute path regardless of where the script was invoked from. dirname "$0" alone gives you a relative path, which breaks as soon as a Vagrant trigger changes directories.

  Block 2 — loop setup (lines 8-17)

  for node in master worker1 worker2; do
    DISK="$(realpath "$DISK_DIR/${node}-data.qcow2")"
    ID_FILE="$PROJECT_DIR/.vagrant/machines/${node}/libvirt/id"

    if [ ! -f "$ID_FILE" ]; then
      echo "ERROR: No libvirt domain ID found for $node — skipping"
      continue
    fi
    DOMAIN=$(cat "$ID_FILE")

  - realpath resolves symlinks and gives an absolute canonical path. Required because virsh attach-disk won't accept relative paths (it runs as root via libvirt, which has no notion of "the project directory").
  - .vagrant/machines/<node>/libvirt/id is where vagrant-libvirt stores the libvirt domain UUID for each VM. Reading it is the programmatic way to answer "which libvirt domain is this Vagrant VM?" without parsing virsh list. If this file doesn't exist, the VM hasn't
  been created yet — hence the continue.
  - Note the name mismatch for your project: proyecto uses short names (master), your create-disks.sh uses test-master. When you port this, you'll need to pick one scheme and apply it consistently to qcow2 filenames, the for loop, and the .vagrant/machines/ path.

  Block 3 — attach the disk (lines 19-26)

  if $VIRSH domblklist "$DOMAIN" | grep -q "vdb"; then
    echo "$node: vdb already attached"
  else
    echo "$node: attaching $DISK as vdb"
    $VIRSH attach-disk "$DOMAIN" "$DISK" vdb \
      --driver qemu --subdriver qcow2 --persistent
  fi

  - domblklist lists block devices attached to a domain. The idempotence check is "if vdb is already in the list, skip." Simple and correct.
  - vdb is the target device name inside the guest. vda is already used by Vagrant for the root disk (the Ubuntu box), so vdb is the next slot. Linux kernel names virtio block devices alphabetically.
  - --driver qemu --subdriver qcow2: tells libvirt this is a qcow2 file that qemu should read natively (not raw). Without --subdriver qcow2, libvirt might treat the file as raw bytes and the VM would see garbage.
  - --persistent: writes the attachment into the domain's XML definition, so it survives shutdown/reboot. Without this flag the attach is live-only.

  Block 4 — SSH into the guest, format and mount (lines 29-67)

  This is where the script crosses the host/guest boundary. Everything between <<'REMOTE' and REMOTE runs on the VM.

  ssh -o StrictHostKeyChecking=no "$node" bash -s <<'REMOTE'
    set -e
    ...
  REMOTE

  - bash -s tells the remote bash to read its script from stdin — which is the heredoc content. This is how you ship a multi-line script over SSH without creating a temp file.
  - <<'REMOTE' (quoted delimiter) disables host-side variable expansion. Inside the heredoc, $i and $(seq 1 10) are passed through literally and evaluated on the guest, not on the host. If you removed the quotes, bash on your laptop would expand $i to nothing before
  sending the script over.
  - set -e makes the remote script abort on any failed command. Without it, a failed mkfs.ext4 would silently continue and you'd mount a half-broken filesystem.

  Wait for the block device (lines 33-41)

  for i in $(seq 1 10); do
    [ -b /dev/vdb ] && break
    sleep 1
  done
  [ ! -b /dev/vdb ] && { echo "ERROR: /dev/vdb not found"; exit 1; }

  virsh attach-disk returns immediately, but the kernel's hotplug path (udev creating /dev/vdb) is asynchronous. This polls for up to 10 seconds. -b tests that the path is a block device — more precise than -e (which would accept any file).

  Format only if empty (lines 43-49)

  if ! sudo blkid /dev/vdb &>/dev/null; then
    echo "Formatting /dev/vdb as ext4"
    sudo mkfs.ext4 -q /dev/vdb
  else
    echo "/dev/vdb already has a filesystem"
  fi

  This is the most important idempotence check in the script. blkid returns success only when the device has a known filesystem signature. If someone runs the provisioner twice, mkfs would wipe all your data — this guard prevents that. Note the sudo is necessary because
   blkid reads raw block devices, which non-root users can't.

  Mountpoint + fstab (lines 51-58)

  sudo mkdir -p /mnt/data

  if ! grep -q '/dev/vdb' /etc/fstab; then
    echo '/dev/vdb /mnt/data ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab >/dev/null
  fi

  - mkdir -p is idempotent by nature (no error if the directory exists).
  - nofail is the critical fstab option: if /dev/vdb is missing at boot (say, you detached the disk for debugging), the VM will still boot instead of dropping into emergency mode. In a lab this is lifesaving.
  - 0 2: dump=0 (no backup), pass=2 (fsck runs at boot, but after the root filesystem). Order matters here — root is always pass=1.

  Mount (lines 60-66)

  if ! mountpoint -q /mnt/data; then
    sudo mount /mnt/data
  fi

  mountpoint -q returns 0 if the path is an active mount point. Because fstab was already written, mount /mnt/data (without specifying the device) looks up the entry and mounts it. Cleaner than mount /dev/vdb /mnt/data because you only define the device/options in one
  place.

  How this connects to your create-disks.sh

  Your script handles step 1 (qcow2 files exist on the host). attach-disks.sh picks up from step 2:

  create-disks.sh            attach-disks.sh
  ----------------            ----------------
  qcow2 file on host    →    virsh attach-disk (--persistent)
                        →    kernel hotplug → /dev/vdb
                        →    mkfs.ext4 (first time only)
                        →    /etc/fstab entry (nofail)
                        →    mount /mnt/data

  The two scripts are designed to be triggered in order: before :up on master creates the qcow2 files, the VMs boot, then after :up on the last VM attaches and mounts them. Splitting them like this is deliberate — creation is host-local and fast, while attach requires
  all VMs to be running and their .vagrant/machines/*/libvirt/id files to exist.

  Things to watch when porting

  1. Naming: proyecto uses master, your create-disks.sh uses test-master. The for loop, the qcow2 filename, and the .vagrant/machines/<name>/ path all need to agree. Since your create script already uses test-*, you probably want for node in test-master test-worker1
  test-worker2.
  2. SSH host resolution: this script uses ssh "$node" with short hostnames (master). That works because scripts/ssh-config.sh wrote entries to ~/.ssh/config. Your project already has the equivalent (ssh test-master), so this should just work with the renamed nodes.
  3. Trigger placement: in proyecto's Vagrantfile, this script runs as trigger.after :up, only_on: 'worker2' (the last VM). Make sure you wire yours to fire after all VMs are up.

  Want me to draft an attach-disks.sh adapted to your test-* naming, or walk through how to wire the trigger into your Vagrantfile?

---------------------------------------------------------------------------------------------------------------------

# Versión en español

Recorramos `attach-disks.sh` bloque a bloque. Voy a señalar las partes que no son obvias y las que tendrás que adaptar para tu nomenclatura `test-*`.

★ Insight ─────────────────────────────────────
- **Dos contextos de ejecución en un mismo script**: los comandos exteriores (líneas 1-27) se ejecutan en el **host** (tu máquina Arch) porque solo el host puede hablar con libvirt. El heredoc (líneas 29-67) se ejecuta **dentro de la VM invitada** por SSH. Confundir estos dos contextos es la trampa más común al escribir scripts de provisioning — un `sudo` dentro del heredoc significa sudo en la VM, no en tu portátil.
- **Todo el script es idempotente por diseño**: cada acción destructiva está protegida por una comprobación tipo "¿esto ya existe?". Eso es lo que permite a `vagrant up` volver a ejecutar los triggers sobre un cluster ya provisionado sin romper nada. La idempotencia es la propiedad central que diferencia un script de provisioning de un script de instalación.
- **`--persistent` lo cambia todo**: sin este flag, `attach-disk` solo afecta a la VM en ejecución — un reinicio pierde la conexión del disco. Con él, la definición XML del dominio se actualiza, así que libvirt vuelve a conectar el disco en cada arranque futuro. Por eso el script no necesita volver a ejecutarse tras un `vagrant halt` + `vagrant up`.
─────────────────────────────────────────────────

## Bloque 1 — configuración inicial (líneas 1-6)

```bash
VIRSH="virsh -c qemu:///system"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
DISK_DIR="$PROJECT_DIR/disks"
```

- `qemu:///system` es la conexión **a nivel de sistema** de libvirt (corre como root, gestionada por `libvirtd`). La alternativa es `qemu:///session` (por-usuario, más ligera). Vagrant-libvirt usa la conexión de sistema por defecto, así que tu script tiene que coincidir — si no, estarías mirando un conjunto de VMs distinto.
- `SCRIPT_DIR` / `PROJECT_DIR` usan el truco de `cd + pwd` para obtener una ruta **absoluta** independientemente de dónde se haya invocado el script. `dirname "$0"` a solas te da una ruta relativa, que se rompe en cuanto un trigger de Vagrant cambia de directorio.

## Bloque 2 — preparación del bucle (líneas 8-17)

```bash
for node in master worker1 worker2; do
  DISK="$(realpath "$DISK_DIR/${node}-data.qcow2")"
  ID_FILE="$PROJECT_DIR/.vagrant/machines/${node}/libvirt/id"

  if [ ! -f "$ID_FILE" ]; then
    echo "ERROR: No libvirt domain ID found for $node — skipping"
    continue
  fi
  DOMAIN=$(cat "$ID_FILE")
```

- **`realpath`** resuelve enlaces simbólicos y devuelve una ruta absoluta canónica. Es obligatorio porque `virsh attach-disk` no acepta rutas relativas (se ejecuta como `root` a través de libvirt, que no tiene noción de "el directorio del proyecto").
- **`.vagrant/machines/<node>/libvirt/id`** es donde vagrant-libvirt guarda el UUID del dominio libvirt para cada VM. Leer este fichero es la forma programática de responder "¿qué dominio de libvirt es esta VM de Vagrant?" sin parsear la salida de `virsh list`. Si el fichero no existe, la VM aún no se ha creado — de ahí el `continue`.
- Ojo con la discrepancia de nombres en tu proyecto: `proyecto` usa nombres cortos (`master`), tu `create-disks.sh` usa `test-master`. Al portarlo, tienes que elegir un esquema y aplicarlo consistentemente a los nombres de los qcow2, al bucle `for`, y a la ruta `.vagrant/machines/`.

## Bloque 3 — conectar el disco (líneas 19-26)

```bash
if $VIRSH domblklist "$DOMAIN" | grep -q "vdb"; then
  echo "$node: vdb already attached"
else
  echo "$node: attaching $DISK as vdb"
  $VIRSH attach-disk "$DOMAIN" "$DISK" vdb \
    --driver qemu --subdriver qcow2 --persistent
fi
```

- **`domblklist`** lista los dispositivos de bloque conectados a un dominio. La comprobación de idempotencia es "si `vdb` ya aparece en la lista, saltamos". Simple y correcto.
- **`vdb`** es el nombre del dispositivo destino dentro del invitado. `vda` ya lo usa Vagrant para el disco raíz (la box de Ubuntu), así que `vdb` es la siguiente posición. El kernel de Linux nombra los dispositivos de bloque virtio alfabéticamente.
- **`--driver qemu --subdriver qcow2`**: le dice a libvirt que este es un fichero qcow2 que qemu debe leer de forma nativa (no raw). Sin `--subdriver qcow2`, libvirt podría tratar el fichero como bytes crudos y la VM vería basura.
- **`--persistent`**: escribe la conexión del disco en la definición XML del dominio, así sobrevive a apagado/reinicio. Sin este flag la conexión solo existe mientras la VM está viva.

## Bloque 4 — SSH al invitado, formatear y montar (líneas 29-67)

Aquí es donde el script cruza la frontera host/invitado. Todo lo que está entre `<<'REMOTE'` y `REMOTE` se ejecuta en la VM.

```bash
ssh -o StrictHostKeyChecking=no "$node" bash -s <<'REMOTE'
  set -e
  ...
REMOTE
```

- **`bash -s`** le dice al bash remoto que lea su script desde stdin — que es el contenido del heredoc. Así puedes enviar un script multilínea por SSH sin crear un fichero temporal.
- **`<<'REMOTE'`** (delimitador entre comillas) desactiva la expansión de variables del lado del host. Dentro del heredoc, `$i` y `$(seq 1 10)` se pasan literales y se evalúan **en el invitado**, no en el host. Si quitaras las comillas, bash en tu portátil expandiría `$i` a nada antes de enviar el script.
- **`set -e`** hace que el script remoto aborte si falla cualquier comando. Sin él, un `mkfs.ext4` fallido seguiría silenciosamente y acabarías montando un sistema de ficheros medio roto.

### Esperar al dispositivo de bloque (líneas 33-41)

```bash
for i in $(seq 1 10); do
  [ -b /dev/vdb ] && break
  sleep 1
done
[ ! -b /dev/vdb ] && { echo "ERROR: /dev/vdb not found"; exit 1; }
```

`virsh attach-disk` devuelve el control inmediatamente, pero la ruta de hotplug del kernel (udev creando `/dev/vdb`) es asíncrona. Esto hace polling hasta 10 segundos. `-b` comprueba que la ruta sea un dispositivo de bloque — más preciso que `-e` (que aceptaría cualquier fichero).

### Formatear solo si está vacío (líneas 43-49)

```bash
if ! sudo blkid /dev/vdb &>/dev/null; then
  echo "Formatting /dev/vdb as ext4"
  sudo mkfs.ext4 -q /dev/vdb
else
  echo "/dev/vdb already has a filesystem"
fi
```

**Esta es la comprobación de idempotencia más importante del script.** `blkid` devuelve éxito solo cuando el dispositivo tiene una firma de sistema de ficheros conocida. Si alguien ejecuta el provisioner dos veces, `mkfs` borraría todos tus datos — esta guarda lo impide. Fíjate que el `sudo` es necesario porque `blkid` lee dispositivos de bloque en crudo, algo a lo que los usuarios no-root no tienen acceso.

### Punto de montaje + fstab (líneas 51-58)

```bash
sudo mkdir -p /mnt/data

if ! grep -q '/dev/vdb' /etc/fstab; then
  echo '/dev/vdb /mnt/data ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab >/dev/null
fi
```

- `mkdir -p` es idempotente por naturaleza (no da error si el directorio ya existe).
- **`nofail`** es la opción crítica de fstab: si `/dev/vdb` falta en el arranque (por ejemplo, porque desconectaste el disco para depurar), la VM arrancará igualmente en lugar de caer en modo de emergencia. En un lab esto es vital.
- **`0 2`**: `dump=0` (sin backup), `pass=2` (fsck corre en el arranque, pero después del sistema de ficheros raíz). El orden aquí importa — root siempre es `pass=1`.

### Montar (líneas 60-66)

```bash
if ! mountpoint -q /mnt/data; then
  sudo mount /mnt/data
fi
```

`mountpoint -q` devuelve 0 si la ruta es un punto de montaje activo. Como fstab ya se escribió, `mount /mnt/data` (sin especificar el dispositivo) busca la entrada y monta. Más limpio que `mount /dev/vdb /mnt/data` porque así solo defines el dispositivo/opciones en un único sitio.

## Cómo conecta esto con tu `create-disks.sh`

Tu script se encarga del paso 1 (los ficheros qcow2 existen en el host). `attach-disks.sh` continúa desde el paso 2:

```
create-disks.sh            attach-disks.sh
----------------            ----------------
qcow2 en el host      →    virsh attach-disk (--persistent)
                      →    hotplug del kernel → /dev/vdb
                      →    mkfs.ext4 (solo la primera vez)
                      →    entrada en /etc/fstab (nofail)
                      →    mount /mnt/data
```

Los dos scripts están diseñados para dispararse en orden: `before :up` en master crea los ficheros qcow2, las VMs arrancan, y luego `after :up` en la última VM los conecta y monta. Separarlos así es deliberado — la creación es local al host y rápida, mientras que el attach necesita que todas las VMs estén arriba y sus ficheros `.vagrant/machines/*/libvirt/id` existan.

## Cosas a vigilar al portarlo

1. **Nombres**: `proyecto` usa `master`, tu `create-disks.sh` usa `test-master`. El bucle `for`, el nombre del qcow2 y la ruta `.vagrant/machines/<name>/` tienen que coincidir. Como tu script de creación ya usa `test-*`, lo más probable es que quieras `for node in test-master test-worker1 test-worker2`.
2. **Resolución de hosts SSH**: este script usa `ssh "$node"` con nombres cortos (`master`). Eso funciona porque `scripts/ssh-config.sh` escribió entradas en `~/.ssh/config`. Tu proyecto ya tiene el equivalente (`ssh test-master`), así que debería funcionar directamente con los nombres renombrados.
3. **Colocación del trigger**: en el Vagrantfile de `proyecto`, este script se ejecuta como `trigger.after :up, only_on: 'worker2'` (la última VM). Asegúrate de conectar el tuyo para que se dispare después de que todas las VMs estén arriba.

¿Quieres que prepare un `attach-disks.sh` adaptado a tu nomenclatura `test-*`, o que repasemos cómo enganchar el trigger en tu Vagrantfile?
