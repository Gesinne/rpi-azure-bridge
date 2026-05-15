#!/bin/bash
#
# Script para aplicar todos los fixes pendientes al flow Node-RED
# Uso: sudo bash aplicar_fixes.sh
#
# Lanza en orden los scripts fix_*.sh idempotentes (si ya están aplicados,
# no hacen nada). Pensado para ejecutarse:
#   - Tras actualizar_flow.sh (porque sobrescribe flows.json con la versión nueva
#     y los fixes locales se pierden)
#   - Como saneamiento manual cuando se sospechen problemas en MQTT/Kibana
#
# Fixes incluidos (al 2026-05-15):
#   1. fix_process_mqtt_timestamp.sh
#      Bug del umbral 10000 ms vs segundos en Process MQTT que mantenía datos
#      fantasma durante 2.7 h. Fix: 10 segundos reales.
#   2. fix_disable_hola_inject.sh
#      Deshabilita los 3 inject "hola" cada 0.5s que publicaban payloads
#      Modbus fantasma por MQTT y enmascaraban fallos reales.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Aplicar fixes a flow Node-RED"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

FIXES=(
  "fix_process_mqtt_timestamp.sh"
  "fix_disable_hola_inject.sh"
)

for fix in "${FIXES[@]}"; do
  script="$SCRIPT_DIR/$fix"
  if [ ! -x "$script" ]; then
    chmod +x "$script" 2>/dev/null || true
  fi
  if [ ! -f "$script" ]; then
    echo "  [X] No encontrado: $script — skip"
    continue
  fi
  echo ""
  echo "  ▶ Ejecutando $fix..."
  echo "  ────────────────────────────────────────────"
  if "$script"; then
    echo "  [OK] $fix completado"
  else
    echo "  [X] $fix falló (exit $?). Abortando."
    exit 1
  fi
done

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [OK] Todos los fixes aplicados"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
