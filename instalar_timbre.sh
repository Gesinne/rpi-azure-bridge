#!/bin/bash
#
# Deja este equipo listo para que se le pueda abrir el acceso remoto desde el panel.
# No toca Node-RED ni el flow.
#
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "Ejecútalo con sudo."; exit 1; }

DIR="$(dirname "$(readlink -f "$0")")"
USUARIO="${SUDO_USER:-gesinne}"

echo "[1/4] Secreto del equipo (la llave con la que se firman las órdenes)"
if [ -s /etc/gesinne/timbre.key ]; then
    echo "  ya tenía uno; se conserva"
else
    "$DIR/timbre_acceso.py" --generar-secreto >/dev/null
    echo "  generado"
fi
chmod 755 /etc/gesinne 2>/dev/null || true
chown "$USUARIO" /etc/gesinne/timbre.key 2>/dev/null || true
chmod 600 /etc/gesinne/timbre.key 2>/dev/null || true
echo -n "  apúntalo para darlo de alta en el servidor: "
cat /etc/gesinne/timbre.key; echo ""

echo "[2/4] Clave del túnel"
CLAVE="/home/$USUARIO/.ssh/id_tunel"
if [ ! -f "$CLAVE" ]; then
    sudo -u "$USUARIO" ssh-keygen -t ed25519 -f "$CLAVE" -N '' -q
    echo "  generada"
else
    echo "  ya existía"
fi
echo "  clave pública (para el alta en el servidor):"
cat "${CLAVE}.pub"

echo "[3/4] Permiso para abrir y cerrar el túnel sin contraseña"
cat > /etc/sudoers.d/gesinne-acceso <<SUDO
$USUARIO ALL=(root) NOPASSWD: $DIR/acceso_remoto.sh
SUDO
chmod 440 /etc/sudoers.d/gesinne-acceso
visudo -c >/dev/null

echo "[4/4] Servidor de acceso, credenciales y servicio"
install -d -m 755 /etc/gesinne
printf 'GESINNE_TUNEL_HOST=%s\nGESINNE_TUNEL_PORT=%s\n' \
    "${GESINNE_TUNEL_HOST:-acceso.gesinne.cloud}" "${GESINNE_TUNEL_PORT:-443}" \
    > /etc/gesinne/acceso.conf
chmod 644 /etc/gesinne/acceso.conf
echo "  llamará a $(grep HOST /etc/gesinne/acceso.conf | cut -d= -f2):$(grep PORT /etc/gesinne/acceso.conf | cut -d= -f2)"

if [ -n "${GESINNE_MQTT_USER:-}" ] && [ -n "${GESINNE_MQTT_PASS:-}" ]; then
    install -d -m 755 /etc/gesinne
    printf 'GESINNE_MQTT_USER=%s\nGESINNE_MQTT_PASS=%s\n' "$GESINNE_MQTT_USER" "$GESINNE_MQTT_PASS" \
        > /etc/gesinne/mqtt.conf
    chmod 600 /etc/gesinne/mqtt.conf   # lo lee systemd como root, no el servicio
    echo "  credenciales guardadas en /etc/gesinne/mqtt.conf"
elif [ -r /etc/gesinne/mqtt.conf ]; then
    echo "  ya había credenciales guardadas"
else
    echo "  OJO: sin credenciales el broker rechaza la conexión."
    echo "  Vuelve a lanzarlo así:  sudo GESINNE_MQTT_USER=timbre GESINNE_MQTT_PASS=... $0"
fi

cat > /etc/systemd/system/gesinne-timbre.service <<UNIT
[Unit]
Description=Escucha la orden de abrir el acceso remoto (Gesinne)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USUARIO
# Lo lee systemd (como root) y se lo pasa al servicio: así el fichero puede seguir
# siendo 600 de root y el proceso no necesita leerlo él.
EnvironmentFile=-/etc/gesinne/mqtt.conf
ExecStart=$DIR/timbre_servicio.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now gesinne-timbre.service
sleep 2
systemctl is-active gesinne-timbre.service && echo "  en marcha"
