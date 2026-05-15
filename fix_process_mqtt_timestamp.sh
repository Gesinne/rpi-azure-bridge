#!/bin/bash
#
# Script para corregir el bug 10000 -> 10 segundos en Process MQTT
# Uso: sudo bash fix_process_mqtt_timestamp.sh
#
# Por qué: en la function "Process MQTT" la variable se llama timestampMillis
# pero contiene SEGUNDOS (Date.now() / 1000). La comparación < 10000 hacía
# que el payload Modbus FANTASMA se siguiera publicando durante 10000 segundos
# (2.7 horas) tras la última lectura real. El umbral correcto es 10 segundos.
#
# Lo que hace:
# 1. Backup del flows.json con timestamp
# 2. Sustituye '< 10000) {' por '< 10) {' dentro de la function Process MQTT
# 3. Si ya está aplicado → NO-OP (idempotente)
# 4. Reinicia Node-RED y verifica
#
# Para revertir: restaurar el backup *.before_mqtt_ts_fix_*

set -euo pipefail

FLOWS="/home/gesinne/.node-red/flows.json"
BACKUP="${FLOWS}.before_mqtt_ts_fix_$(date +%Y%m%d_%H%M%S)"

if [ ! -f "$FLOWS" ]; then
  echo "ERROR: $FLOWS no existe en esta RPi"
  exit 1
fi

echo "=== 1. Backup ==="
sudo cp "$FLOWS" "$BACKUP"
ls -la "$BACKUP"

echo
echo "=== 2. Aplicar fix ==="
python3 << PYEOF
import json
path = "$FLOWS"
with open(path) as f:
    flows = json.load(f)

OLD = "if (timestampMillis - contextData.segundoModbus < 10000) {"
NEW = "if (timestampMillis - contextData.segundoModbus < 10) {  // FIX: era 10000 (segundos vs millis)"

cambios = 0
ya_aplicado = 0
for n in flows:
    if not isinstance(n, dict) or n.get("type") != "function":
        continue
    if n.get("name") != "Process MQTT":
        continue
    func = n.get("func", "")
    if OLD in func:
        n["func"] = func.replace(OLD, NEW)
        cambios += 1
        print(f"  Process MQTT (id={n['id'][:8]}): umbral 10000 -> 10")
    elif "< 10) {" in func and "FIX" in func:
        ya_aplicado += 1
        print(f"  Process MQTT (id={n['id'][:8]}): ya estaba arreglado")

if cambios > 0:
    with open(path, "w") as f:
        json.dump(flows, f, indent=4)
    print(f"OK, {cambios} cambios aplicados")
else:
    print(f"NO-OP: el fix ya estaba aplicado ({ya_aplicado} encontrados)")
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
echo "OK. Backup en: $BACKUP"
echo "Revertir: sudo cp \"$BACKUP\" \"$FLOWS\" && sudo systemctl restart nodered"
