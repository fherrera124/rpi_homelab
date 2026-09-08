# RPi Homelab Infrastructure

Este repositorio contiene la configuración centralizada de la infraestructura y los servicios para un entorno homelab basado en Raspberry Pi. La arquitectura está definida bajo un modelo de Infraestructura como Código (IaC) mediante Ansible.

---

## Despliegue Automatizado (Ansible)

El ciclo de vida del servidor, incluyendo instalación de paquetes, despliegue de configuraciones y sincronización de código, se ejecuta de forma centralizada a través del playbook de aprovisionamiento.

### 1. Requisitos Previos (Nodo de Control)
* Instalación local de `ansible` o `ansible-core`.
* Disponibilidad de la contraseña para descifrar el entorno de Ansible Vault.

### 2. Autenticación y Credenciales (SSH)
Ansible requiere acceso SSH basado en claves criptográficas (passwordless authentication) hacia el nodo de destino para ejecutar las tareas de forma desatendida.

**Generación de clave (ED25519):**
Si el nodo de control no dispone de una clave SSH, generar una utilizando el algoritmo de curva elíptica ED25519:
```bash
ssh-keygen -t ed25519 -a 100 -C "ansible-control"
```

**Distribución de la clave pública:**
Exportar la identidad al servidor de destino para autorizar la conexión. Reemplazar user y la dirección IP por los valores correspondientes al entorno local:
```bash
ssh-copy-id user@192.168.100.47
```
**Validación de acceso:**
Confirmar que el nodo de control puede establecer sesión sin requerimiento de contraseña (prompt de clave):
```bash
ssh user@192.168.100.47
```
**3. Gestión de Secretos**
La información sensible (tokens de Cloudflare, claves API) se almacena cifrada. Para auditar o modificar estas variables globales:
```bash
EDITOR=nano ansible-vault edit group_vars/vault.yml
```
**4. Comandos útiles de test**
```bash
# Solo lee todos tus archivos YAML y verifica estructura y formato
ansible-playbook site.yml --syntax-check --ask-vault-pass
#Dry run, se conecta y hace simulacro de ejecucion
ansible-playbook site.yml --check --ask-vault-pass
#Muestra qué líneas de texto se borrarían o agregarían en el servidor, tal como si fuera un git diff
ansible-playbook site.yml --check --diff --ask-vault-pass
**5. Ejecución del Playbook**
Para aprovisionar un nodo desde cero o aplicar deltas de configuración, ejecutar el siguiente comando desde la raíz del repositorio local:
```bash
ansible-playbook --ask-vault-pass
```
Operaciones automatizadas: El playbook compila la estructura de directorios en /opt/rpi_homelab, inyecta los enlaces simbólicos de Nginx, transfiere el código fuente mediante rsync y emite las señales de reinicio a los demonios afectados.

---

## Audio Multiroom: Snapcast + Soloist (rol `04_snapcast`)

La Raspberry actúa como **hub de distribución de audio**: recibe Spotify Connect vía Soloist y lo reparte por Snapcast a los clientes de la LAN. No reproduce sonido localmente.

### Cadena de audio

```
soloist  --pipewire-device soloist_sink
   |
   v   Soloist hace dlopen de libpulse.so.0. No tiene backend ALSA ni salida
   |   a stdout, por eso el puente vía PulseAudio es obligatorio.
pipewire-pulse + module-pipe-sink
   |
   v
/run/snapcast/soloist   (FIFO s16le 48000 2ch, creado por systemd-tmpfiles)
   |
   v
snapserver  ->  opus  ->  snapclients de la LAN (1704/1705/1780)
                          + Snapweb en http://<ip>:1780
```

Un solo stream en **opus** (~128 kbps) alcanza para todos los clientes: es lo que
aguantan los ESP32 por wifi (con PCM a ~1,5 Mbps aparecen `audio starved`), y
Snapweb tambien lo decodifica — su bundle incluye `opus-decoder` en WASM junto a
`libflac.js`, verificado sobre el paquete instalado.

El FIFO se declara en `/etc/tmpfiles.d/` en lugar de crearlo un servicio: `/run` es tmpfs y se vacía en cada arranque, y así queda con dueño y permisos correctos **antes** de que arranquen snapserver y el pipe-sink. Si lo creara snapserver (que corre como `_snapserver`), el pipe-sink no podría escribirlo.

Soloist corre bajo un usuario de sistema dedicado (`soloist`, sin login) con **linger** habilitado, que sostiene su sesión `systemd --user` donde viven PipeWire, WirePlumber, el pipe-sink y el propio Soloist.

### Requisito: API key en el vault

El rol falla de entrada si falta la credencial. Obtenerla en [developer.spotify.com/dashboard/soloist](https://developer.spotify.com/dashboard/soloist) (requiere cuenta Premium para *generarla*; después pueden conectarse cuentas Free) y cargarla:

```bash
ansible-vault edit group_vars/all/vault.yml
# agregar:  vault_soloist_api_key: spak_xxxxxxxxxxxxxxxxxxxx
```

**Limitación conocida:** Soloist exige `--api-key` como argumento y no lee variables de entorno, así que la key queda visible en la línea de comandos del proceso (`ps aux`). Es del binario, no del despliegue.

### Restricción de arquitectura

El build `arm32` que publica Spotify es **ARMv7**. Funciona en Pi 2, 3, 4 y 5; **no** en Pi 1 ni Zero, que son ARMv6. El rol aborta con un mensaje explícito si detecta una arquitectura sin build disponible.

### Snapweb no viene en el paquete Debian

El paquete `snapserver` de Debian instala solo un **placeholder** en
`/usr/share/snapserver/snapweb` (un `index.html` de 2 KB que explica como
instalar la interfaz real). El rol descarga el `.deb` oficial desde las releases
de GitHub, que instala la aplicacion en `/usr/share/snapweb`, y apunta ahi el
`doc_root` de snapserver.

### Metadata y control desde Snapweb

El rol instala un *control script* de Snapcast en
`/usr/share/snapserver/plug-ins/meta_soloist.py`, que publica en la API de Snapcast
lo que Soloist esta reproduciendo (titulo, artista, album, caratula, duracion,
posicion) y traduce en sentido inverso los comandos de transporte: los botones
play/pause/next/prev/seek de Snapweb controlan Spotify de verdad.

Habla con Soloist a traves de `soloist ctl`, no con una libreria WebSocket de
Python: es una dependencia menos que instalar en la Pi.

**Por que el puerto de la WS es fijo.** Soloist publica el puerto asignado en
`<data-dir>/ws.port`, pero ese archivo vive en un directorio `700` del usuario
`soloist` y snapserver ejecuta el control script como `_snapserver`, que no puede
leerlo. Fijandolo con `--ws 127.0.0.1:9876` el script se conecta sin
tocar permisos. Escucha solo en loopback.

**Dos detalles del protocolo que cuestan un rato descubrir:**

- Snapserver agrega `--stream`, `--snapcast-host` y `--snapcast-port` a lo que se
  declare en `controlscriptparams`. Si el script no los acepta, `getopt` aborta con
  `option --stream not recognized` y el plugin muere al arrancar.
- Spotify publica `play` y `pause` en `available_actions` de forma mutuamente
  excluyente segun el estado, pero Snapcast usa `canPlay`/`canPause` para *habilitar*
  comandos: con `canPause` en false rechaza el comando con
  `Stream property canPause is false`. Por eso el script pone ambos en true cuando
  cualquiera de las dos acciones esta disponible.

El volumen queda deliberadamente fuera: Snapcast ya tiene volumen por cliente, que es
el que corresponde. Mapearlo a Soloist bajaria la fuente para todos los parlantes a
la vez.

### Exposicion externa (`snapcast.tunegociosmart.com.ar`)

> **La proteccion vive en Cloudflare Access, no en la Pi.**
> Snapcast **no tiene autenticacion de ningun tipo**: su JSON-RPC responde `200` sin
> credenciales. Con el control script instalado, eso significa control total sobre la
> reproduccion de Spotify y sobre el volumen de cada parlante de la casa, ademas de
> ver que se esta escuchando.
>
> El vhost se despliega **a proposito sin auth**. Si se publica el hostname en el
> tunel SIN una politica de Access configurada, queda abierto a internet.

Configuracion del lado de Cloudflare (no la hace Ansible):

1. **Zero Trust → Networks → Tunnels →** el tunel → *Public Hostname*:
   `snapcast.tunegociosmart.com.ar` → `http://localhost:80`, para que nginx rutee
   por `Host` igual que el resto de los vhosts.
2. **Access → Applications → Add a self-hosted application** con ese dominio.
3. Politica *Allow* por email. El proveedor *One-time PIN* viene habilitado de
   fabrica, no hace falta conectar Google ni GitHub.

Del lado de la Pi, el rol `01_infra` despliega:

- `nginx/snapcast.j2` → proxy a `127.0.0.1:1780`.
- `nginx/websocket-upgrade.conf.j2` → un `map` en `conf.d` que resuelve la cabecera
  `Connection` segun el request.

**Snapweb abre DOS WebSockets, y los dos hay que proxearlos:**

| Path | Para que |
|---|---|
| `/jsonrpc` | Control y metadata. Ese path recibe **ademas** POST de JSON-RPC plano. |
| `/stream` | El audio, en frames binarios (`binaryType = "arraybuffer"`). |

Que `/jsonrpc` sirva para las dos cosas es lo que obliga al `map`: hardcodear
`Connection "upgrade"` romperia los POST. Y olvidarse de `/stream` da un sintoma
enganoso — la metadata y los controles andan perfecto, pero no hay audio y el
navegador tira un error de WebSocket al recargar, porque snapserver devuelve `404` a
un GET normal sobre un endpoint que solo existe como WebSocket.

Por eso las cabeceras de upgrade van a **nivel de `server`** y las hereda todo el
vhost. Ambos paths comparten un `location` con `proxy_read_timeout 3600s` y
`proxy_buffering off`: son conexiones largas y continuas, y sin eso nginx las corta y
el audio llega a tirones.

Verificado de punta a punta desde una red externa, con Access delante: metadata,
control y audio funcionando, con `101 Switching Protocols` en ambos endpoints.

> Al validar cambios en este vhost, no confiar en un `curl` inmediatamente despues de
> `systemctl reload nginx`: los workers viejos siguen sirviendo la configuracion
> anterior un instante mas. `/var/log/nginx/access.log` muestra lo que realmente esta
> pasando.

**Sin verificar todavia:** Snapweb instalado como PWA (trae `manifest.webmanifest`)
conviviendo con el flujo de login por redireccion de Access.

### Vencimiento a los 90 días

Los builds de Soloist expiran (salen con exit code 10). El rol instala `update-soloist.timer`, que corre los domingos a las 04:00 (con hasta 1h de jitter), compara checksums y sólo reinstala y reinicia si el binario cambió de verdad.

### Variables principales

Están en `roles/04_snapcast/defaults/main.yml` y se sobreescriben desde `group_vars`:

| Variable | Default | Notas |
|---|---|---|
| `soloist_device_name` | `Snapcast Hub RPi2` | Nombre en la app de Spotify |
| `soloist_cache_mb` | `500` | El default de Soloist es ilimitado: sobre SD es desgaste y riesgo de llenar la partición |
| `snapcast_codec` | `opus` | Lo decodifican tanto los ESP32 como Snapweb |
| `snapcast_buffer_ms` | `500` | |
| `snapweb_version` | `0.9.3` | Ver nota sobre Snapweb mas arriba |
| `soloist_ws_port` | `9876` | Puerto de la WS de Soloist, solo loopback |
| `soloist_nice` / `soloist_cpu_weight` | `5` / `50` | Para que el audio no le gane CPU a servicios críticos |

### Operación

```bash
# estado
sudo systemctl status snapserver
sudo -u soloist XDG_RUNTIME_DIR=/run/user/$(id -u soloist) systemctl --user status soloist

# logs de Soloist (unit de usuario)
sudo journalctl _SYSTEMD_USER_UNIT=soloist.service -f

# forzar chequeo de actualización del binario
sudo /usr/local/sbin/update-soloist.sh

# clientes conectados
curl -s -H "Content-Type: application/json" \
  -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' \
  http://127.0.0.1:1780/jsonrpc | python3 -m json.tool
```

Interfaz web de Snapweb: `http://<ip-de-la-pi>:1780`

**Primer emparejamiento:** abrir Spotify en la misma LAN y elegir el dispositivo con el nombre de `soloist_device_name`. Soloist loguea `waiting for login` hasta que ocurra.

---

## Operaciones y Diagnóstico (Nodo de Destino)
Comandos para la administración y auditoría de la infraestructura directamente en el servidor.

Gestión del Proxy Inverso (Nginx)
```bash
# Validar la integridad y sintaxis de los archivos .conf activos
sudo nginx -t

# Recargar la configuración en memoria sin interrumpir las conexiones TCP activas
sudo systemctl reload nginx

# Auditar eventos de enrutamiento fallido o bloqueos de upstream (502 Bad Gateway)
sudo tail -n 50 /var/log/nginx/error.log

# Auditar tráfico entrante (requiere forzar cabeceras Host para debugear Cloudflare)
sudo tail -n 50 /var/log/nginx/access.log
```
**Gestión de Procesos de Aplicación (PM2):**
El demonio de PM2 es instanciado por Ansible a nivel de sistema (root). La visualización e interacción requiere elevación de privilegios explícita.
```bash
# Imprimir la tabla de estado, identificadores de proceso, uso de memoria y uptime
sudo pm2 status

# Monitorear la salida estándar (stdout) y de errores (stderr) en tiempo real
sudo pm2 logs monitor-app

# Emitir señal de reinicio al proceso del backend
sudo pm2 restart monitor-app
```
**Gestión del Frontend (Nginx):**
```bash
sudo systemctl status nginx
sudo systemctl restart nginx
sudo tail -n 20 /var/log/nginx/error.log  # Ver errores del servidor web
```
**Nota:**
Para aplicar configuraciones nuevas o cambios en los enlaces simbólicos, siempre es mejor usar `reload` en lugar de `restart`:
```bash
sudo systemctl reload nginx
```
