# Documentación: Instalación y Configuración de Cloudflare Tunnel (Zero Trust)

## 1. Arquitectura General
* **Gestión de Tráfico de Entrada:** Cloudflare Tunnel (Remote-managed).
* **Reverse Proxy Principal:** Nginx escucha en el puerto `80`.

---

## 2. Fase 1: Creación del Túnel e Instalación en RPi

La conexión entre la Raspberry Pi y la red de Cloudflare se establece mediante un agente local llamado `cloudflared`.

1. **En la Nube:** Ingresar al panel web de **Cloudflare Zero Trust**.
2. Navegar a **Networks -> Tunnels** y hacer clic en **Add a tunnel**.
3. Seleccionar **Cloudflared** como tipo de conector y asignarle un nombre (ej. `rpi-homelab`).
4. **En la Raspberry Pi:** Seleccionar el entorno correspondiente (Debian/Ubuntu) y copiar el comando de instalación proporcionado por Cloudflare.
5. Veras instrucciones de instalación:
   ```bash
   sudo cloudflared service install eyJhbGciOiJIUzI1NiIsIn... (tu token único)
   ```
6. Copiar el token en `vault_cf_tunnel_token`:
   ```bash
   EDITOR=nano ansible-vault edit group_vars/vault.yml
   ```
---

## 3. Fase 2: Configuración de Enrutamiento (Public Hostnames)

La administración del tráfico se realiza exclusivamente desde la web (`Networks -> Tunnels -> Configure -> Public Hostnames`).

Cualquier dominio o subdominio debe apuntar directamente a la puerta nativa de la Raspberry Pi:
* **Type:** `HTTP` (el tunel es intrinsicamente seguro, no hay necesidad de HTTPS)
* **URL:** `127.0.0.1:80` *(o `localhost:80`)*

---

## 4. Fase 3: Despliegue de Dominios y Alta Disponibilidad (Wildcard)

Publicar las aplicaciones locales a internet. En el apartado de túneles (`Networks -> Tunnels`), seleccionar el túnel creado y dirígirse a la pestaña **Published application routes** (*Allow your Tunnel to reach applications whose domains you connected to Cloudflare*). 

Al hacer clic en agregar un host (*Publish a local application to the Internet via public hostname. DNS will be automatically configured*), configuraremos las siguientes dos rutas:

### A. Dominio Principal (Creación Automática)
1. Agrega una ruta para el dominio raíz (`tunegociosmart.com.ar`), apuntando a `HTTP://127.0.0.1:80`
2. Resultado: Cloudflare se encarga automáticamente de crear el registro DNS tipo `CNAME` en la tabla pública de DNS apuntando hacia el túnel. El dominio principal ya queda operativo.

### B. Subdominios Comodín / Wildcard (`*`)
1. En esa misma pestaña, agrega una segunda ruta utilizando un asterisco (`*`) como subdominio, apuntando al mismo destino y con el mismo ajuste SNI activado.
2. Warning de Seguridad: Al guardar, Cloudflare arrojará una advertencia indicando que no creará el registro DNS automáticamente. Esto es una medida de seguridad por diseño para evitar el secuestro accidental de tráfico de otros subdominios existentes.
3. Acción Manual Requerida:
   * Ir al Dashboard clásico de Cloudflare -> DNS -> Records.
   * Identificar y copiar la dirección de destino generada para el dominio principal (es un identificador tipo `[ID-UNICO-DEL-TUNEL].cfargotunnel.com`).
   * Crear manualmente un nuevo registro DNS:
      * Type: `CNAME`
      * Name: `*`
      * Target: Pegar el identificador del túnel (`[ID-UNICO].cfargotunnel.com`).
      * Proxy Status: Proxied (Nube naranja encendida).

---

## 5. Fase 4: Acceso Remoto Seguro (SSH)

Cloudflare permite encapsular el tráfico SSH dentro del túnel, logrando acceso remoto seguro a la terminal sin abrir el puerto 22 en el router ni exponer la IP pública.

### A. Configuración en Zero Trust
**IMPORTANTE - ORDEN DE PRECEDENCIA:** Si tienes configurado un dominio comodín (`*`), las reglas específicas (como SSH) **deben crearse antes** que el comodín. Cloudflare evalúa las rutas de arriba hacia abajo; si el comodín está primero, interceptará el tráfico SSH y causará un error `502 Bad Gateway`.

En la pestaña **Published application routes**, agrega la ruta específica para SSH:
   * **Subdomain:** `ssh`
   * **Domain:** `tunegociosmart.com.ar`
   * **Type:** `SSH`
   * **URL:** `localhost:22`

### B. Configuración en la Máquina Cliente (Ej: Laptop externa)
La computadora desde la que te vas a conectar debe tener instalado el binario de `cloudflared`, descargar desde [acá](https://github.com/cloudflare/cloudflared/releases). 

Para que la conexión sea transparente y no requiera comandos especiales, edita el archivo de configuración SSH local de tu cliente (`nano ~/.ssh/config`) y agrega este bloque:

```text
Host ssh.tunegociosmart.com.ar
    ProxyCommand cloudflared access ssh --hostname %h
```

Para conectar desde cualquier red externa, simplemente ejecuta el comando tradicional:
```bash
ssh tu_usuario@ssh.tudominio.com
```
