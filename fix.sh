#!/bin/bash
# ============================================================================
#  FIX — arregla de una vez todo lo que impide que el equipo lea y envie datos
#  Uso:  sudo bash fix.sh            (o  sudo bash fix.sh --ver  para solo mirar)
# ============================================================================
#
#  QUE HACE, EN ORDEN
#   1. Mira a que velocidad responde cada placa (puede que esten distintas entre
#      ellas tras un cambio a medias: es lo que paso en el 00128 el 7-oct-2026).
#   2. Arregla el flow (fix_flow_todo.py), poniendo el cliente Modbus a la
#      velocidad donde esten las placas:
#        - la cola de envio deja de quedarse clavada (correlar por id)
#        - el boton "Borrar Cola de Envio" pasa a borrar de verdad
#        - se callan los 3 inject "hola" que enmascaraban fallos
#        - el dato de ahora deja de salir detras de dias de cola
#        - y una placa averiada DEJA DE TUMBAR a las demas
#   3. Deja las TRES tarjetas activas. No hace falta desactivar la averiada:
#      con el cliente arreglado, su timeout ya no se lleva por delante a las otras.
#   4. Limpia los contextos huerfanos (los que dejo un flow anterior al
#      regenerarse los ids: ocupan y no los usa nadie).
#   5. Arranca Node-RED y comprueba si de verdad esta leyendo.
#
#  Es idempotente: se puede relanzar. Hace copia del flows.json antes de tocarlo.
# ============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
FLOW="${FLOW:-$(ls /home/*/.node-red/flows.json 2>/dev/null | head -1)}"
CTX="$(dirname "$FLOW")/context"
SOLO_VER=0
[ "${1:-}" = "--ver" ] && SOLO_VER=1

linea() { echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

echo ""; linea
echo "  FIX — $(date '+%d/%m/%Y %H:%M')"
linea
echo "  flow: $FLOW"
[ -f "$FLOW" ] || { echo "  [X] no encuentro flows.json"; exit 1; }

# ── 1. a que velocidad esta cada placa ──────────────────────────────────────
echo ""; echo "  [1/5] Buscando las placas (hay que parar Node-RED para usar el puerto)..."
ESTABA_ACTIVO=0
systemctl is-active --quiet nodered && ESTABA_ACTIVO=1
[ "$ESTABA_ACTIVO" = "1" ] && systemctl stop nodered

BUSCA=$(timeout 300 python3 "$DIR/cambia_velocidad_placa.py" --buscar 2>/dev/null)
echo "$BUSCA" | grep -E "^  L[0-9]|no contesta" | sed 's/^/   /'
BAUDS=$(echo "$BUSCA" | grep -oE 'responde a [0-9]+ baud' | grep -oE '[0-9]+')
BAUD=$(echo "$BAUDS" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
if [ -z "$BAUD" ]; then
    echo "   [!] ninguna placa contesta: no toco la velocidad del flow."
    echo "       Eso ya no es configuracion — mira el par, la tension o las placas."
    BAUD=""
else
    echo "   -> la mayoria de placas responde a $BAUD baud"
fi

# ── 2. arreglar el flow ─────────────────────────────────────────────────────
echo ""; echo "  [2/5] Arreglando el flow..."
if [ "$SOLO_VER" = "1" ]; then
    python3 "$DIR/fix_flow_todo.py" "$FLOW" --check 2>&1 | sed 's/^/   /'
else
    if [ -n "$BAUD" ]; then
        python3 "$DIR/fix_flow_todo.py" "$FLOW" --apply --baud "$BAUD" 2>&1 | sed 's/^/   /'
    else
        python3 "$DIR/fix_flow_todo.py" "$FLOW" --apply 2>&1 | sed 's/^/   /'
    fi
fi

# ── 3. las tres tarjetas activas ────────────────────────────────────────────
echo ""; echo "  [3/5] Dejando las tres tarjetas activas..."
if [ "$SOLO_VER" = "1" ]; then
    python3 "$DIR/fix_tarjetas.py" --listar 2>&1 | sed 's/^/   /'
else
    python3 "$DIR/fix_tarjetas.py" --todas --no-reinicio 2>&1 | sed 's/^/   /'
fi

# ── 4. contextos huerfanos ──────────────────────────────────────────────────
echo ""; echo "  [4/5] Limpiando contextos de nodos que ya no existen..."
if [ -d "$CTX" ]; then
    for d in "$CTX"/*/; do
        id=$(basename "$d")
        [ "$id" = "global" ] && continue
        if ! grep -q "\"$id\"" "$FLOW" 2>/dev/null; then
            TAM=$(du -sh "$d" 2>/dev/null | cut -f1)
            if [ "$SOLO_VER" = "1" ]; then
                echo "   huerfano: $id ($TAM)"
            else
                rm -rf "$d" && echo "   borrado huerfano: $id ($TAM)"
            fi
        fi
    done
else
    echo "   (no hay directorio de contexto)"
fi

# ── 5. arrancar y comprobar ─────────────────────────────────────────────────
echo ""; echo "  [5/5] Arrancando Node-RED y comprobando..."
systemctl start nodered
sleep 25
ERR=$(journalctl -u nodered --since "20 seconds ago" --no-pager -o cat 2>/dev/null | grep -cE "Timed out|queue cleared")
OK=$(journalctl -u nodered --since "20 seconds ago" --no-pager -o cat 2>/dev/null | grep -c "Connected to broker")
echo "   errores Modbus en 20 s: $ERR"
echo "   conexion al broker: $([ "$OK" -gt 0 ] && echo si || echo 'aun no')"
echo ""; linea
if [ "$ERR" -lt 5 ]; then
    echo "  LISTO. Mira la pagina de tensiones en un par de minutos."
else
    echo "  Sigue habiendo errores Modbus ($ERR en 20 s)."
    echo "  Si alguna placa no contesta a ninguna velocidad, es hardware:"
    echo "  par, tension o la propia placa. Ejecuta:  python3 scan_modbus_extendido.py"
fi
linea; echo ""
