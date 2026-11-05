#!/bin/bash
#
# Quita a Tailscale la gestion del DNS de la RPi.
#
# POR QUE
# Con --accept-dns activado, Tailscale reescribe /etc/resolv.conf y manda TODAS
# las consultas a su resolver interno (100.100.100.100), que las reenvia. Por 4G
# eso se paga en cada conexion: medido en el Q0001 (CORTIZO), 0,48 s de DNS y
# 3,6 s para abrir github.com. Sin ello: 0,13 s y 1,19 s. Tres veces mas rapido,
# y se nota sobre todo en apt y git, que abren decenas de conexiones.
#
# Lo unico que se pierde es resolver por su nombre corto los equipos de la
# tailnet; por su IP 100.x se sigue llegando igual. En una RPi de campo no hace
# falta: quien resuelve nombres es la persona desde su PC, no el equipo.
#
# Es idempotente: si ya estaba, no hace nada.
#
#   sudo bash fix_dns_tailscale.sh
#
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "Ejecutalo con sudo."; exit 1; }

command -v tailscale >/dev/null || { echo "[-] esta RPi no tiene tailscale: nada que hacer"; exit 0; }

ANTES=$(grep -c '100\.100\.100\.100' /etc/resolv.conf 2>/dev/null || true)
if [ "$ANTES" = "0" ]; then
    echo "[=] el DNS ya no lo gestiona Tailscale"
    exit 0
fi

echo "[*] antes:"
sed -n '1,12p' /etc/resolv.conf | grep -E '^nameserver|^search' || true

tailscale set --accept-dns=false
sleep 2

echo "[*] despues:"
sed -n '1,12p' /etc/resolv.conf | grep -E '^nameserver|^search' || true

# Prueba de que la resolucion sigue funcionando: si se quedara sin DNS, el
# equipo no podria ni publicar por MQTT (mqtt.gesinne.cloud es un nombre).
if getent hosts mqtt.gesinne.cloud >/dev/null; then
    echo "[OK] resuelve mqtt.gesinne.cloud"
else
    echo "[X] NO resuelve mqtt.gesinne.cloud: devolviendo el DNS a Tailscale"
    tailscale set --accept-dns=true
    exit 1
fi
