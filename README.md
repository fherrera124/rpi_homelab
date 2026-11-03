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
EDITOR=nano ansible-vault edit group_vars/all/vault.yml
```

**4. Código fuente cifrado (`apps/**`, git-crypt)**

El código propio bajo `apps/` (`portfolio`, `monitor-app`) se cifra en el repositorio con
[git-crypt](https://github.com/AGWA/git-crypt) — declarado en `.gitattributes` como
`apps/** filter=git-crypt diff=git-crypt`. Es una herramienta distinta de Ansible Vault:
Vault cifra variables de Ansible con una contraseña; git-crypt cifra archivos del árbol de
trabajo con una llave binaria, de forma transparente en cada `git add`/`checkout`. Así el
código de las apps nunca queda en texto plano en GitHub, sin necesitar que el repo sea privado.

Es modo llave simétrica (no GPG): una única llave de 256 bits, sin usuarios asociados. Esa
llave **vive solo dentro de `.git/`** del checkout donde se corrió `git-crypt init` — no es
un archivo del repositorio, así que **no viaja con `git clone`**. Un clone nuevo ve `apps/**`
como binario cifrado (arranca con la firma `\0GITCRYPT\0`) hasta desbloquearlo con una copia
exportada de la llave:

```bash
# Aplicar un archivo de llave exportado (deja apps/** en texto plano en este checkout):
git-crypt unlock /ruta/al/archivo-de-llave

# Exportar una copia portable de la llave, desde un checkout ya desbloqueado:
git-crypt export-key /ruta/de/salida
```

Guardar el archivo exportado en un gestor de contraseñas (o backup fuera del repo) es
responsabilidad de quien lo genera — **nunca commitear la llave**, y perderla sin backup deja
`apps/**` irrecuperable en cualquier clone nuevo.

**5. Comandos útiles de test**
```bash
# Solo lee todos tus archivos YAML y verifica estructura y formato
ansible-playbook site.yml --syntax-check --ask-vault-pass
#Dry run, se conecta y hace simulacro de ejecucion
ansible-playbook site.yml --check --ask-vault-pass
#Muestra qué líneas de texto se borrarían o agregarían en el servidor, tal como si fuera un git diff
ansible-playbook site.yml --check --diff --ask-vault-pass
```
**6. Ejecución del Playbook**
Para aprovisionar un nodo desde cero o aplicar deltas de configuración, ejecutar el siguiente comando desde la raíz del repositorio local:
```bash
ansible-playbook --ask-vault-pass
```
Operaciones automatizadas: El playbook compila la estructura de directorios en /opt/rpi_homelab, inyecta los enlaces simbólicos de Nginx, transfiere el código fuente mediante rsync y emite las señales de reinicio a los demonios afectados.

**7. Volver al estado base (`teardown.sh`)**
`teardown.sh` (como root, en la Pi) deshace lo que aplica el playbook: nginx, PM2, cloudflared,
las apps y el stack de audio completo (Soloist, MPD/myMPD, Snapcast/Snapweb, Icecast/darkice
y los servicios de la Sangean, incluido el desenmascarado de `snapclient.service`). Pide
confirmación antes de empezar y deja la Pi lista para volver a correr el playbook.

---

## Audio Multiroom: Snapcast + Soloist (roles `04_snapcast`, `05_icecast_bridge`, `06_sangean`)

La Raspberry actúa como **hub de distribución de audio**: recibe Spotify Connect vía Soloist y radio por internet vía MPD, y los reparte por Snapcast a los clientes de la LAN. Todos los parlantes escuchan lo mismo, y gana el último que dio play. No reproduce sonido localmente.

El área se separa en tres roles, de más genérico a más específico:

- **`04_snapcast`** — el hub en sí: sesión de Soloist, MPD + myMPD para la radio,
  Snapserver con la fuente `Casa`, el árbitro `ultimo-play`, Snapweb y el control
  script de metadata. No sabe nada de Icecast ni de la Sangean.
- **`05_icecast_bridge`** — el stream HTTP por Icecast/darkice para equipos que no
  hablan Snapcast: publica lo que suene en el sink `icecast_sink`. No tiene
  ninguna referencia a la Sangean en su código (la menciona solo como ejemplo, en
  un comentario); si mañana aparece otro equipo que necesite un stream ICY, es
  este rol el que sirve.
- **`06_sangean`** — todo lo específico de la Sangean WFR-28: el cliente que
  reproduce `Casa` en `icecast_sink` y ocupa la fila de la radio en Snapweb, y el
  encendido automático por DLNA. Es el único de los tres pensado para desaparecer
  del todo si se cambia de equipo (ver
  [Cómo dar de baja la Sangean](#cómo-dar-de-baja-la-sangean)).

`site.yml` los corre en ese orden porque `05_icecast_bridge` depende de variables
del hub (`soloist_user`) y `06_sangean` depende de variables del puente
(`icecast_mount`, para armar la URL que empuja por DLNA, e `icecast_sink`) — no hay
`meta/main.yml` entre ellos, es orden manual como el resto del playbook.

### Cadena de audio

```
soloist  --pipewire-device soloist_sink
   |
   v   Soloist hace dlopen de libpulse.so.0. No tiene backend ALSA ni salida
   |   a stdout, por eso el puente vía PulseAudio es obligatorio.
pipewire-pulse + module-pipe-sink
   |
   v
/run/snapcast/soloist   (FIFO s16le 44100 2ch, creado por systemd-tmpfiles)
   |
   v
snapserver: Soloist ─┐
                     ├─> Casa  ->  flac  ->  snapclients de la LAN (1704/1705/1780)
snapserver: Radio ───┘                       + Snapweb en http://<ip>:1780
   ^                                         + snapclient de la Sangean -> Icecast
   |
/run/snapcast/mpd   (FIFO s16le 44100 2ch)
   ^
   |
mpd  <-  myMPD en http://<ip>:8800
```

Un solo stream en **flac**, sin perdida, a **44,1 kHz / 16 bits**: la tasa nativa de
Spotify, para que no haya resampleo en ningun punto de la cadena. Para eso el rol
tambien fija el reloj de PipeWire a esa tasa (`10-soloist-rate.conf`); sin eso el grafo
corre a 48 kHz y el audio se resamplearia a la entrada y a la salida. Snapweb decodifica
FLAC con `libflac.js` (verificado sobre el paquete instalado).

**El costo es ancho de banda**: FLAC ronda 0,7-1 Mbps por cliente, contra ~128 kbps de
opus. Antes se uso opus porque los ESP32 por wifi mostraban `audio starved` con PCM a
~1,5 Mbps; FLAC queda en un punto intermedio **que no esta verificado en esos clientes**.
Si aparece, `snapcast_codec: opus` lo revierte, a costa de fidelidad.

**Que se conserva y que no.** Con el volumen de Spotify al 100 % y a la misma tasa, la
cadena Soloist → FLAC no altera las muestras. Tres limites:

- **El slider de volumen de Spotify atenua el audio dentro de la Pi**, antes del FIFO.
  Medido en `rpi2`: con el slider en una posicion intermedia el stream de Soloist estaba
  en `pipewire-pulse` al 68 % (−10,15 dB) y despues al 80 %; con el slider al maximo,
  100 %. Para Soloist, el volumen de Spotify *es* el volumen de ese stream: forzarlo a
  100 % con `pactl` hace que emita `volume_changed 100` y el slider se vaya con el.
  Por eso, sobre PipeWire, **hay que dejar el slider de Spotify en 100 %** y regular el
  volumen en Snapweb o en cada cliente. Una alternativa que lo evitaria esta planteada
  en [`docs/research/soloist-pulse-shim.md`](docs/research/soloist-pulse-shim.md)
  (rama `research/soloist-pulse-shim`); no esta implementada.
- **El volumen por cliente de Snapweb tambien escala las muestras**, pero en cada cliente,
  despues de decodificar el FLAC: no afecta a los demas.
- **El FIFO es de 16 bits.** Hoy Soloist entrega s16 para el catalogo normal, asi que no
  se pierde nada. Spotify Lossless es FLAC de 24 bits / 44,1 kHz
  ([9to5Google](https://9to5google.com/2025/09/10/spotify-finally-adds-lossless-24-bit-audio-quality/)):
  cuando llegue a la region, Soloist lo entregara como FLOAT32 y aqui se reducira a
  16 bits. Pasar a 24 requiere `soloist_sink_format: s24-32le`, `24` en el
  `sampleformat` de snapserver y clientes que lo soporten; no esta probado.

La rama MP3 para la Sangean es con perdida por limitacion de la radio.

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
play/pause/next/prev de Snapweb controlan Spotify de verdad.

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

El script no traduce el volumen: Snapcast ya tiene volumen por cliente, que es el que
corresponde para balancear parlantes. Ojo que eso no significa que el volumen de Spotify
no actue: Soloist lo aplica por su cuenta al stream dentro de la Pi y baja la fuente
para todos los parlantes a la vez (ver *Que se conserva y que no*).

**Snapweb 0.9.3 no dibuja barra de progreso.** El script publica `duration` y
`position` correctamente, pero el bundle de Snapweb los parsea y los guarda en su
modelo sin usarlos nunca: lo unico que renderiza del stream es `artUrl`, `title` y
`artist`. `setPosition` no aparece ni una vez en el bundle, asi que `canSeek` tampoco
habilita nada. 0.9.3 es la ultima version publicada y ninguna release menciona la
funcion — no se arregla actualizando. Los campos se publican igual, para cualquier
otro cliente de la API.

**Por que hay un latido de un segundo (`tick_loop`).** `properties()` extrapola la
posicion a partir de `position_ms` + `timestamp_ms`, pero eso solo corre al publicar,
y Soloist emite `playback_state` unicamente en cambios de track o de estado.
Publicando solo ahi, snapserver se quedaba con la foto tomada milisegundos despues
del ultimo cambio y la servia congelada: `position` valia siempre ~0.07 s. El hilo
`tick_loop` republica cada segundo mientras `playbackStatus` es `playing`; en pausa
no publica nada.

### Radio por internet y la fuente `Casa`

La radio la reproduce **MPD**, que escribe al FIFO `/run/snapcast/mpd` en el mismo
formato que Soloist (44,1 kHz / 16 bits; si la emisora transmite a otra tasa, MPD la
convierte). Se maneja desde **myMPD**, una pagina pensada para el celular:
`http://<ip-de-la-pi>:8800`. myMPD viene del repositorio de su autor en el Open
Build Service; el rol verifica la huella de la clave antes de agregarlo.

**Favoritas y pantalla de inicio.** El rol carga `radio_favorites` (La 100, Mitre,
Metro, Aspen, Rock & Pop, Vorterix) como favoritas y como botones del *Inicio* de
myMPD, mas un boton *Buscar radio*. Cada cosa se carga solo si myMPD no tiene
ninguna, asi que lo que la familia agregue o borre no se pisa en el siguiente
despliegue. Tocar una radio en el *Inicio* o en las favoritas la pone a sonar.

Para sumar una radio: *Buscar radio*, con el nombre en `Name` y, si se quiere,
`Argentina` en `Country`. Busca en [Radio Browser](https://www.radio-browser.info/), la
misma base que usa Music Assistant; la base propia de myMPD (WebradioDB) casi no tiene
radios argentinas. La radio elegida queda en *Navegar → (icono de capas) → Radios web
favoritas*; desde su menu, *Agregar a la pantalla inicial* le da su boton. El script se
baja fijado a un commit de `jcorporation/mympd-scripts` y con checksum.

Dos ajustes de myMPD que el rol cambia, porque lo que trae de fabrica es incomodo:

- **Tocar una favorita la reemplaza y la reproduce** (`clickRadioFavorites:
  replacePlay`); de fabrica solo la agrega a la fila, sin sonar.
- **Los botones del *Inicio* se crean como `stream` y con *Reemplazar fila y
  reproducir***, con un JavaScript propio que el rol copia a
  `/var/lib/mympd/config/custom_js`. No va como variable `MYMPD_CUSTOM_JS` porque
  myMPD descarta las variables de mas de 100 caracteres. De fabrica se
  crean como `webradio` y sin reproducir, y myMPD 26 tiene un error con los `webradio`:
  suenan la primera vez y despues arman una URL rota (`Webradio not found`) hasta
  recargar la pagina. El script reemplaza la funcion `addRadioFavoriteToHome` de myMPD:
  si una version nueva la renombra, los botones vuelven a crearse como de fabrica.

**Una sola fuente para los grupos.** Snapserver tiene tres streams: `Soloist` y `Radio`
con `codec=null`, que solo alimentan, y el stream `meta` `Casa`, que es el que
escuchan los grupos y el unico que se codifica. Snapserver oculta los streams `null`:
no aparecen en Snapweb ni en `Server.GetStatus`, y no notifican sus cambios de estado. `Casa` suena con la entrada de mayor
prioridad que este activa (Soloist primero). Un cliente nuevo cae en `Casa` solo,
porque snapserver salta los streams `null` al elegir el default. El
titulo y la caratula de Spotify siguen llegando a Snapweb: el meta stream reenvia las
propiedades de la entrada activa.

**Gana el ultimo play (`ultimo-play.py`).** La prioridad sola no alcanza: snapserver
marca un pipe como `idle` tras 100 ms de silencio digital, y entre tema y tema Spotify
hace huecos de 0,4 a 2,5 s, asi que una radio sonando de fondo se colaria en cada
cambio de tema; y pausar Spotify devolveria la radio que alguien dejo prendida. Como
los streams `null` no notifican nada, el daemon sigue a los reproductores
directamente: a Soloist con `soloist ctl trace` y a MPD con `idle player`. Cuando uno
arranca, pausa al otro (`soloist ctl pause` o `pause 1`). `buffering` cuenta como
sonando, para que un cambio de tema de Spotify no pase por un play nuevo.

El mismo daemon **vuelve a encender la salida de MPD** si alguien la apaga: en myMPD,
el menu del parlante muestra la salida `Snapcast` como un boton, y tocarlo deja la
radio muda con "All audio outputs are disabled".

**El volumen de myMPD baja la radio dentro de la Pi** (`mixer_type "software"`),
igual que el slider de Spotify con Spotify: quien use solo myMPD o solo la app de
Spotify puede regular el volumen sin abrir Snapweb. Snapweb queda para emparejar
ambientes. Si uno queda alto y el otro bajo, el volumen salta al pasar de una fuente a
la otra. La perdida de resolucion que se evita con Spotify no aplica a la radio, que
ya llega comprimida a 64-96 kbps. MPD arranca en pausa
despues de un reinicio (`restore_paused`), para que un corte de luz no prenda la radio
a la madrugada.

**myMPD solo atiende en la LAN** (`MYMPD_ACL`), sin HTTPS ni usuario: no se publica
por Cloudflare como Snapweb.

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

### Stream HTTP para radios de internet (Icecast + darkice) — rol `05_icecast_bridge`

Para equipos que no hablan snapcast — una Sangean WFR-28, por ejemplo — el rol
publica ademas el audio como **stream MP3** que se sintoniza como si fuera una
emisora: `http://<ip>:8000/soloist.mp3`.

```
Casa  ->  snapclient local  ->  icecast_sink.monitor  ->  darkice  ->  Icecast  ->  radios de la LAN
```

**darkice lee del monitor de un sink nulo** (`icecast_sink`, unit de usuario
`icecast-sink.service`) en el que un snapclient de la propia Pi reproduce `Casa`; ese
snapclient lo pone `06_sangean`. Asi el stream lleva Spotify o radio, lo mismo que el
resto de los parlantes. Se eligio darkice sobre ffmpeg por huella: 18 paquetes contra 169.

Mientras suena la radio, la metadata ICY muestra el texto de reposo: `soloist-icymeta.py`
solo conoce lo que reproduce Soloist.

**MP3 y no flac/opus:** las Frontier Silicon manejan MP3, WMA y AAC; opus en esa
generacion no existe. Esta rama es con perdida por limitacion de la radio.

#### Metadata en la pantalla de la radio

`soloist-icymeta.py` publica el titulo en Icecast como ICY in-band, con formato
`Artista - Titulo` (y `Show - Episodio` para podcasts, que no traen artistas).

Dos detalles que cuestan encontrar:

- **`charset=UTF-8` es obligatorio** en `/admin/metadata`. Sin el, Icecast
  reinterpreta el UTF-8 y `Mienteme` llega a la radio como `MiÃ©nteme`.
- Icecast **pierde la metadata al reiniciar**, y el script solo publica cuando el
  titulo cambia. Por eso reenvia igual cada 60s: si no, el titulo se queda vacio
  hasta el siguiente tema.

#### El shim de nginx

`nginx/stream-lan.j2` publica el mismo stream en el puerto 80 y **contesta los
HEAD localmente**. Existe porque Icecast responde `400` a cualquier HEAD, y
algunos equipos validan la URI con un HEAD antes de aceptarla: la Sangean lo
hace, y por DLNA fallaba con `errorCode 716` sin llegar a mirar el contenido.

Vive físicamente en `01_infra/templates/nginx/` (ahí es donde se despliega
Nginx), pero es propiedad de facto de `06_sangean`: es la única razón de que
exista. Por eso `01_infra` lo despliega bajo
`when: sangean_enabled or sangean_wake_enabled` en vez de incondicional — si se
da de baja la Sangean, este vhost deja de publicarse solo.

### La Sangean — rol `06_sangean`

#### Limites conocidos de la Sangean WFR-28

Verificado sobre el equipo, para no volver a intentarlo:

- **No muestra caratula, y no es cuestion de tamano ni de formato.** Se probaron
  cuatro variantes de DIDL-Lite (`musicTrack` y `audioBroadcast`, con y sin
  `dlna:profileID=JPEG_TN`, con `protocolInfo` DLNA), con y sin `Stop` previo,
  sirviendo un JPEG real desde la propia Pi. La radio *guarda* el `albumArtURI`
  (lo devuelve intacto en `GetMediaInfo`) pero **nunca hace un solo pedido HTTP**
  por la imagen.
- **En modo DLNA no pide metadata ICY.** Puesta detras de un proxy que inyecta
  `StreamUrl` in-band, sus tres conexiones (dos HEAD y un GET) llegaron sin
  `Icy-MetaData: 1`. Hay dos canales de metadata excluyentes: empujada por DLNA
  toma el titulo del DIDL, sintonizada como emisora toma el ICY.
- **Icecast no transporta `StreamUrl`.** `/admin/metadata?...&url=...` responde
  `200` con "Metadata update successful" pero descarta el parametro: el bloque
  in-band solo lleva `StreamTitle`.
- **No implementa `SetNextAVTransportURI`**: no figura en su SCPD.
- **Los botones de transporte no llegan a UPnP.** Pausa, play, next y prev no
  mueven el `TransportState` ni emiten GENA, aunque el eventing funciona (un
  `Pause` por SOAP si dispara evento). El **boton de mute es la excepcion**: si
  emite un evento de `RenderingControl`.
- **`SetVolume` y `SetMute` si funcionan**, y cambian el volumen audible
  mientras reproduce el stream (verificado a oido, no solo por el valor releido).
- Se la puede **despertar de standby y ponerla a reproducir** con
  `SetAVTransportURI` + `Play` (~1.4s).

#### La Sangean como cliente de Snapweb

La radio se alimenta de Icecast y no de snapcast. El rol levanta un `snapclient`
en la sesion de audio del usuario `soloist` que **reproduce `Casa` en
`icecast_sink`** (`--player pulse --soundcard icecast_sink`), de donde lo toma
darkice, y ocupa la fila de la radio en Snapweb. Su `--mixer script` no toca el
audio: traduce el slider a SOAP contra el `RenderingControl` de la radio.

```
Snapweb  ->  snapserver  ->  snapclient  ->  sangean-mixer.sh  ->  SOAP
                                  |
                                  +-> icecast_sink  ->  darkice  ->  Icecast  ->  radio
```

Tres cosas que cuestan una tarde si no se saben:

- **El mixer recibe el volumen normalizado** (`--volume 0.550000`), no en
  porcentaje. UPnP quiere un entero 0-100: sin convertir, la radio descarta el
  `SetVolume` en silencio y parece que el slider no hiciera nada, mientras que el
  mute funciona igual. Ese sintoma asimetrico es la pista.
- **El paquete `snapclient` deja habilitado su propio `snapclient.service`**, que
  arranca un cliente real sacando audio por el jack de la placa y aparece en
  Snapweb como `rpi2`. El rol lo enmascara.
- **Arrastrar el slider dispara decenas de invocaciones.** El mixer coalesce con
  `flock`: cada invocacion deja el valor deseado en `$RUNTIME_DIRECTORY/deseado`
  y solo la que gana el lock envia, releyendo hasta que se estabiliza.

Limitaciones que no tienen arreglo dentro de este diseno:

- La radio va **segundos detras** de los demas clientes por el buffer de Icecast.
  Si comparten ambiente, hay eco.
- **La presencia miente**: el proceso corre en la Pi, asi que figura conectado
  aunque la radio este apagada.
- **Pausa, next y prev siguen siendo del stream**, no del dispositivo. El
  equivalente por dispositivo es el mute.

#### Encendido automatico (`sangean-wake.py`)

Cuando `Casa` pasa a `playing`, la radio se enciende sola: empezas a
reproducir en Spotify o en myMPD y suena. El daemon se cuelga del puerto de control de
snapserver y actua solo en la **transicion** a `playing`, con un cooldown para
que un parpadeo no la encienda dos veces.

**Va por push DLNA**: dos llamadas SOAP al mismo endpoint que ya usa
`sangean-mixer.sh`, sin PIN ni sesion.

```
POST http://<radio>:8080/AVTransport/control   SetAVTransportURI  (URL + DIDL)
POST http://<radio>:8080/AVTransport/control   Play
```

**El push la saca de standby por su cuenta.** Verificado partiendo de
`netRemote.sys.power=0`: pasa a reproduciendo en **3,1 s** y entra en modo `5`
(DMR), que por la FSAPI ni siquiera es seleccionable a mano.

Antes de empujar pregunta `GetTransportInfo` + `GetMediaInfo`: si la radio ya
esta en `PLAYING` con esa misma URL no hace nada (0,1 s), porque re-empujar
`SetAVTransportURI` reinicia el stream y con el burst de Icecast eso es un corte
audible por nada.

**La URL apunta a nginx (puerto 80), no a Icecast (8000).** No es un detalle
menor: la radio valida la URI con un `HEAD` antes de aceptarla e Icecast
responde `400` a cualquier `HEAD`, asi que apuntada al 8000 falla con
`errorCode 716` (*resource not found*) sin llegar a mirar el audio. Quien
contesta ese `HEAD` es el vhost `stream-lan` del rol `01_infra`, que existe
exactamente para esto.

**El precio, elegido a conciencia: la pantalla queda muda.** Con la fuente
empujada la radio nunca pide metadata ICY --verificado contra un proxy propio
con las tres clases DIDL, `audioBroadcast` incluida: las tres conexiones
llegaron sin `Icy-MetaData: 1`--, asi que `netRemote.play.info.text` queda vacio
y solo se ve el `dc:title` estatico. Tampoco busca el `albumArtURI`. Y no se
puede refrescar despues: `SetNextAVTransportURI` no existe en su SCPD, y
re-empujar la URI reinicia el stream. Es todo o nada.

A cambio es determinista: **siempre suena esta URL**, sin depender de cual fue
la ultima emisora sintonizada. Ese era el problema del camino anterior por
FSAPI, que solo sabia retomar la ultima escuchada.

Los modos que publica el equipo: `0` Internet radio, `1` Spotify, `2` Music
player, `3` FM, `4` AUX in, `5` DMR. El ultimo no aparece en el menu: se entra
solo cuando algo le empuja contenido por DLNA, que es justo lo que hace este
daemon.

#### Cómo dar de baja la Sangean

Si el equipo se reemplaza o se deja de usar, la baja es local a este rol:

1. Sacar `06_sangean` de `roles:` en `site.yml`.
2. Borrar `ansible/roles/06_sangean/`.
3. Antes de correr el playbook, detener lo que ya no se va a gestionar:
   `sudo systemctl disable --now sangean-wake` y, en la sesion de `soloist`,
   `systemctl --user disable --now snapclient-sangean`. El `snapclient.service`
   del paquete queda enmascarado, no hace falta tocarlo.

El hub (`04_snapcast`) y el puente (`05_icecast_bridge`) no se tocan, pero sin
el snapclient de la Sangean nadie reproduce en `icecast_sink` y el stream HTTP
queda en silencio: si otro equipo lo necesita, hay que dejar un snapclient
equivalente apuntado a ese sink. El vhost
`stream-lan` (en `01_infra`) deja de desplegarse solo, por la condición descrita
en [El shim de nginx](#el-shim-de-nginx) — no hace falta editar `01_infra` para
la baja.

### Vencimiento a los 90 días

Los builds de Soloist expiran (salen con exit code 10). El rol instala `update-soloist.timer`, que corre los domingos a las 04:00 (con hasta 1h de jitter), compara checksums y sólo reinstala y reinicia si el binario cambió de verdad.

### Variables principales

Cada rol trae las suyas en su propio `defaults/main.yml`, y se sobreescriben desde
`group_vars` igual que siempre — al estar los tres en el mismo play, cualquiera puede
referenciar variables de los otros (p. ej. `sangean_stream_url`, en `06_sangean`, arma
la URL con `icecast_mount`, que vive en `05_icecast_bridge`).

**`roles/04_snapcast/defaults/main.yml`** (hub):

| Variable | Default | Notas |
|---|---|---|
| `soloist_device_name` | `Snapcast Hub RPi2` | Nombre en la app de Spotify |
| `soloist_cache_mb` | `500` | El default de Soloist es ilimitado: sobre SD es desgaste y riesgo de llenar la partición |
| `snapcast_codec` | `flac` | Sin perdida. `opus` baja el ancho de banda a ~128 kbps si un cliente wifi no aguanta. Solo lo usa `Casa` |
| `snapcast_main_stream_name` | `Casa` | La fuente que escuchan todos los grupos |
| `mympd_http_port` | `8800` | Pagina de la radio |
| `radio_favorites` | 6 radios argentinas | Se cargan solo si myMPD no tiene favoritas |
| `soloist_sink_rate` | `44100` | Tasa del FIFO, de PipeWire y de snapserver; la nativa de Spotify |
| `snapcast_buffer_ms` | `500` | |
| `snapweb_version` | `0.9.3` | Ver nota sobre Snapweb mas arriba |
| `soloist_ws_port` | `9876` | Puerto de la WS de Soloist, solo loopback |
| `soloist_nice` / `soloist_cpu_weight` | `5` / `50` | Para que el audio no le gane CPU a servicios críticos |

**`roles/05_icecast_bridge/defaults/main.yml`** (puente):

| Variable | Default | Notas |
|---|---|---|
| `icecast_enabled` | `true` | Apaga todo el puente (y, en cascada, el vhost `stream-lan` y el wake de la Sangean) |
| `icecast_mount` | `/soloist.mp3` | Path del stream MP3 |
| `icecast_sink` | `icecast_sink` | Sink nulo cuyo monitor publica darkice |
| `darkice_bitrate` | `320` | MP3 CBR. 320 es el maximo del formato; sin verificar que la Sangean lo acepte (si no, bajar a 192 o 128) |

**`roles/06_sangean/defaults/main.yml`** (Sangean):

| Variable | Default | Notas |
|---|---|---|
| `sangean_enabled` | `true` | Cliente que alimenta Icecast y da el volumen en Snapweb |
| `sangean_wake_enabled` | `true` | Encendido automático por DLNA |
| `sangean_host` | `192.168.100.17` | IP de la radio en la LAN |
| `sangean_wake_cooldown` | `60` | Segundos entre encendidos para no re-empujar por un parpadeo |

### Operación

```bash
# estado
sudo systemctl status snapserver
sudo -u soloist XDG_RUNTIME_DIR=/run/user/$(id -u soloist) systemctl --user status soloist

# logs de Soloist (unit de usuario)
sudo journalctl _SYSTEMD_USER_UNIT=soloist.service -f

# radio y arbitro de fuentes
sudo systemctl status mpd mympd ultimo-play
sudo journalctl -u ultimo-play -f

# forzar chequeo de actualización del binario
sudo /usr/local/sbin/update-soloist.sh

# clientes conectados
curl -s -H "Content-Type: application/json" \
  -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' \
  http://127.0.0.1:1780/jsonrpc | python3 -m json.tool
```

Interfaz web de Snapweb: `http://<ip-de-la-pi>:1780`. Radio: `http://<ip-de-la-pi>:8800`

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

---

## Monitor App

El código que despliega Ansible está en `apps/monitor-app/`. La galería incluye
paginación, filtros y borrado de las imágenes visibles. Ver el
[detalle de funcionamiento, despliegue y pruebas](apps/monitor-app/README.md).

## hls-proxy

Proxy HLS para mandar películas a los Chromecast de la casa (versión
catalogo de [hls-proxy](https://github.com/fherrera124/hls-proxy), repo
privado). Solo se usa dentro de la LAN: `http://192.168.100.47:8090/`. No
pasa por Nginx ni por Cloudflare.

Lo instala `roles/03_apps/tasks/hls-proxy.yml`:

- clona el repo en `/opt/rpi_homelab/apps/hls-proxy` con una deploy key de
  solo lectura (`/root/.ssh/hls-proxy_deploy`), por `ssh.github.com:443`
  porque desde la casa el puerto 22 de GitHub está bloqueado;
- arma el `.venv` e instala con pip solo si cambió el código o falta la
  instalación (en la Pi 2 tarda unos 2 minutos y medio);
- escribe `ecosystem.local.json` con la IP y el puerto (`hls_proxy_env` en
  `group_vars/all/vars.yml`) y levanta `hls-catalogo` con el PM2 de root.

Para actualizar solo hls-proxy, desde `ansible/`:

```bash
ansible-playbook site.yml --tags hls-proxy --ask-vault-pass
```

**Primera instalación:** si la deploy key no está cargada en GitHub, el
playbook falla al clonar y muestra la clave pública. Cargarla en el repo
hls-proxy (Settings > Deploy keys, sin permiso de escritura) y volver a
correrlo. La clave queda en `/root/.ssh`, que `teardown.sh` no borra: solo
hay que volver a cargarla si se reinstala el sistema.

```bash
sudo pm2 logs hls-catalogo
sudo pm2 restart hls-catalogo
```
