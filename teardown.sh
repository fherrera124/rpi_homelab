#!/bin/bash

# ==========================================
# HOMELAB TEARDOWN SCRIPT
# ==========================================
# Devuelve la Raspberry Pi a su estado base eliminando Capa 2 y Capa 3.

# Asegurar que se ejecuta como root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Error: Este script debe ejecutarse como root (usa sudo)."
  exit 1
fi

echo "⚠️  Estás a punto de DESTRUIR toda la infraestructura y aplicaciones del homelab."
read -p "¿Estás seguro de continuar? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Operación cancelada."
    exit 1
fi

echo "🚀 Iniciando demolición..."

# 1. Matar procesos y limpiar PM2 del arranque
echo "-> Deteniendo PM2 y Node.js..."
pm2 kill 2>/dev/null || true
pm2 unstartup systemd 2>/dev/null || true

# 2. Desregistrar túnel de Cloudflare
echo "-> Desregistrando túnel de Cloudflare..."
cloudflared service uninstall 2>/dev/null || true

# 3. Detener y deshabilitar servicios
echo "-> Deteniendo servicios de sistema..."
systemctl stop nginx 2>/dev/null || true
systemctl disable nginx cloudflared 2>/dev/null || true

# 4. Purgar dependencias con apt
echo "-> Purgando paquetes instalados..."
apt purge -y nginx nodejs npm cloudflared sqlite3 libsqlite3-dev
apt autoremove -y

# 5. Borrado de directorios y configuración (Tierra Arrasada)
echo "-> Eliminando directorios de infraestructura y estáticos..."
rm -rf /opt/rpi_homelab
rm -rf /var/www/portfolio

echo "-> Limpiando rastros de Nginx..."
rm -rf /etc/nginx/sites-available/monitor-app
rm -rf /etc/nginx/sites-enabled/monitor-app
rm -rf /etc/nginx/sites-available/portfolio
rm -rf /etc/nginx/sites-enabled/portfolio
rm -rf /etc/nginx/sites-available/snapcast
rm -rf /etc/nginx/sites-enabled/snapcast
rm -f /etc/nginx/conf.d/websocket-upgrade.conf

echo "-> Eliminando estado de PM2..."
rm -rf /root/.pm2
rm -f /etc/systemd/system/pm2-root.service

# 6. Desmontar stack de audio (Snapcast + Soloist)
echo "-> Deteniendo Snapcast y Soloist..."
SOLOIST_UID="$(id -u soloist 2>/dev/null || true)"
if [ -n "$SOLOIST_UID" ]; then
  runuser -u soloist -- env "XDG_RUNTIME_DIR=/run/user/${SOLOIST_UID}" \
    systemctl --user disable --now soloist.service soloist-pipe-sink.service 2>/dev/null || true
fi
systemctl disable --now snapserver update-soloist.timer 2>/dev/null || true

echo "-> Purgando paquetes de audio..."
apt purge -y snapserver pipewire pipewire-pulse wireplumber pulseaudio-utils 2>/dev/null || true

echo "-> Eliminando binario, configuracion y unidades de Soloist..."
rm -f /usr/local/bin/soloist
rm -f /usr/local/sbin/update-soloist.sh
rm -f /etc/systemd/system/update-soloist.service
rm -f /etc/systemd/system/update-soloist.timer
rm -f /etc/tmpfiles.d/snapcast-soloist.conf
rm -f /etc/default/soloist
rm -rf /etc/soloist
rm -f /etc/snapserver.conf
rm -rf /run/snapcast

echo "-> Eliminando usuario del sistema de audio..."
loginctl disable-linger soloist 2>/dev/null || true
userdel -r soloist 2>/dev/null || true

systemctl daemon-reload

echo "El servidor está limpio. Puedes volver a ejecutar el playbook de Ansible."
