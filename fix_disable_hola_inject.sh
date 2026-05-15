#!/bin/bash
#
# Script para deshabilitar los inject "hola" del flow Node-RED
# Uso: sudo bash fix_disable_hola_inject.sh
#
# Por qué: los inject "hola" se disparan cada 0.5s y publican un payload Modbus
# FANTASMA por MQTT cuando no hay datos reales recientes. Esto enmascara fallos
# reales de la placa (Kibana sigue mostrando datos "en vivo" aunque el equipo
# esté caído durante hasta 2.7 h).
#
# Lo que hace:
# 1. Backup del flows.json con timestamp
# 2. Marca como d:true (disabled) cualquier inject cuyo payload sea "hola"
# 3. Si todos ya están deshabilitados → NO-OP (idempotente)
# 4. Reinicia Node-RED y verifica que sigue active
#
# Para revertir: restaurar el backup *.before_disable_hola_*

set -euo pipefail

FLOWS="/home/gesinne/.node-red/flows.json"
BACKUP="${FLOWS}.before_disable_hola_$(date +%Y%m%d_%H%M%S)"

if [ ! -f "$FLOWS" ]; then
  echo "ERROR: $FLOWS no existe en esta RPi"
  exit 1
fi

echo "=== 1. Backup ==="
sudo cp "$FLOWS" "$BACKUP"
ls -la "$BACKUP"

echo
echo "=== 2. Deshabilitar inject 'hola' ==="
python3 << PYEOF
import json
path = "$FLOWS"
with open(path) as f:
    flows = json.load(f)

ya_disabled = 0
cambios = 0
for n in flows:
    if not isinstance(n, dict) or n.get("type") != "inject":
        continue
    if str(n.get("payload", "")).lower() != "hola":
        continue
    if n.get("d") is True:
        ya_disabled += 1
        print(f"  inject id={n['id'][:8]} ya estaba deshabilitado")
        continue
    n["d"] = True
    cambios += 1
    print(f"  inject id={n['id'][:8]} repeat={n.get('repeat','-')} -> DESHABILITADO")

if cambios > 0:
    with open(path, "w") as f:
        json.dump(flows, f, indent=4)
    print(f"OK, {cambios} inject deshabilitados ({ya_disabled} ya lo estaban)")
else:
    print(f"NO-OP: los {ya_disabled} inject 'hola' ya estaban deshabilitados")
PYEOF

echo
echo "=== 3. Restart Node-RED ==="
sudo systemctl restart nodered
sleep 8
state=$(systemctl is-active nodered)
echo "Node-RED: $state"
if [ "$state" != "active" ]; then
  echo "WARN: Node-RED no quedó active. Logs:"
  sudo journalctl -u nodered -n 20 --no-pager
  exit 2
fi

echo
echo "=== 4. Verificación ==="
sleep 20
# Subshell + || echo 0: la pipeline puede devolver exit!=0 si grep no matchea
# (con pipefail). Capturamos cero errores correctamente sin abortar el script.
errors=$( ( journalctl -u nodered --since "20 sec ago" --no-pager 2>&1 \
            | grep -iE "error|crash" \
            | grep -v "Timed out" \
            | wc -l ) || echo 0 )
if [ "$errors" -gt 0 ]; then
  echo "ALERTA: $errors errores tras restart (no-timeout). Revisa:"
  journalctl -u nodered --since "20 sec ago" --no-pager 2>&1 \
    | grep -iE "error|crash" \
    | grep -v "Timed out" \
    | head -10 || true
else
  echo "OK: sin errores tras restart"
fi

echo
echo "Backup en: $BACKUP"
echo "Para revertir: sudo cp \"$BACKUP\" \"$FLOWS\" && sudo systemctl restart nodered"
