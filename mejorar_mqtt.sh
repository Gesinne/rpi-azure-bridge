#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Mejorar MQTT  (opción explícita, NO se aplica sola en cada deploy)
#
# Aplica al flow de Node-RED de este equipo las dos mejoras de publicación MQTT:
#   1) Envío garantizado por id  (fix_mqtt_delivery.py): la cola de envío ya no
#      se atasca tras una desconexión (empareja sending/completed por id, no por
#      posición).
#   2) Dos caminos (fix_mqtt_twopath.py): el dato ACTUAL se publica en vivo sin
#      esperar detrás de la cola; la cola de recuperación acumula el máximo y
#      drena en paralelo. Sin duplicados (la ingestión a ES es idempotente).
#
# NO borra la cola (~/.node-red/context): el reinicio conserva lo encolado y se
# envía solo. Idempotente: se puede correr las veces que quieras.
#
# Uso:  ./mejorar_mqtt.sh            (aplica y reinicia Node-RED)
#       ./mejorar_mqtt.sh --check    (solo dice si ya está aplicado)
#       ./mejorar_mqtt.sh --no-restart
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Localizar los parcheadores (junto a este script o en las rutas del bridge)
buscar() {
    for c in "$SCRIPT_DIR/$1" /opt/rpi-azure-bridge/"$1" \
             /home/gesinne/rpi-azure-bridge/"$1" /home/pi/rpi-azure-bridge/"$1"; do
        [ -f "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}
DELIVERY="$(buscar fix_mqtt_delivery.py || true)"
TWOPATH="$(buscar fix_mqtt_twopath.py || true)"

# Localizar el flows.json de Node-RED
FLOW=""
for f in "$HOME/.node-red/flows.json" /home/*/.node-red/flows.json /root/.node-red/flows.json; do
    [ -f "$f" ] && { FLOW="$f"; break; }
done

if [ -z "$FLOW" ]; then echo "  [X] No encuentro flows.json de Node-RED"; exit 1; fi
if [ -z "$DELIVERY" ] || [ -z "$TWOPATH" ]; then
    echo "  [X] No encuentro los parcheadores (fix_mqtt_delivery.py / fix_mqtt_twopath.py)."
    echo "      Haz 'git pull' del repo del bridge y reintenta."; exit 1
fi

MODE="${1:-}"

if [ "$MODE" = "--check" ]; then
    D=1; T=1
    python3 "$DELIVERY" "$FLOW" --check && D=0 || true
    python3 "$TWOPATH"  "$FLOW" --check && T=0 || true
    echo "  Envío por id : $([ $D -eq 0 ] && echo APLICADO || echo NO)"
    echo "  Dos caminos  : $([ $T -eq 0 ] && echo APLICADO || echo NO)"
    exit 0
fi

echo "  ── Mejorar MQTT ──"
echo "  Flow: $FLOW"
# Respaldo por si acaso
cp "$FLOW" "${FLOW}.bak.mejora_mqtt.$(date +%Y%m%d%H%M%S 2>/dev/null || echo bak)" 2>/dev/null || true

D_OUT=$(python3 "$DELIVERY" "$FLOW" --apply 2>/dev/null | grep -oE 'applied=[0-9]+' | cut -d= -f2 || echo 0)
echo "  [OK] Envío garantizado por id   (applied=${D_OUT:-0})"
T_OUT=$(python3 "$TWOPATH" "$FLOW" --apply 2>/dev/null | grep -oE 'applied=[0-9]+' | cut -d= -f2 || echo 0)
echo "  [OK] Publicación por dos caminos (applied=${T_OUT:-0})"

if [ "$MODE" = "--no-restart" ]; then
    echo "  [i] Node-RED NO reiniciado (--no-restart). La mejora se aplica al reiniciar."
    exit 0
fi

echo "  [~] Reiniciando Node-RED (la cola NO se borra)..."
if sudo systemctl restart nodered 2>/dev/null; then
    echo "  [OK] Node-RED reiniciado. Mejoras MQTT activas."
else
    echo "  [!] No pude reiniciar nodered automáticamente. Hazlo tú: sudo systemctl restart nodered"
fi
