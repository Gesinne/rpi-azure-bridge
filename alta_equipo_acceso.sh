#!/bin/bash
#
# Da de alta un equipo en el servidor de acceso: le asigna sus dos puertos y autoriza
# su clave, y sólo la suya, a abrir esos dos y ninguno más.
#
# Esa restricción es lo que impide que una Raspberry comprometida se cuele en el túnel
# de otra. Sin ella, esto no se despliega.
#
#   sudo ./alta_equipo_acceso.sh 73001 "ssh-ed25519 AAAA... gesinne@raspberrypi"
#
set -euo pipefail

CASA=/var/lib/tunel
LLAVES="$CASA/.ssh/authorized_keys"
RANGO_MIN=30000
RANGO_MAX=60000

EQUIPO="${1:-}"
CLAVE="${2:-}"
[ -n "$EQUIPO" ] && [ -n "$CLAVE" ] || { echo "uso: $0 <nº de equipo> \"<clave pública>\""; exit 1; }
[ "$(id -u)" = "0" ] || { echo "Ejecútalo con sudo."; exit 1; }

N=$((10#${EQUIPO}))
HUECO=$(( (N * 2) % (RANGO_MAX - RANGO_MIN) ))
PUERTO_SSH=$((RANGO_MIN + HUECO))
PUERTO_PANTALLA=$((PUERTO_SSH + 1))

# Si ya estaba, se sustituye su línea: así volver a dar de alta un equipo al que se le
# cambió la tarjeta no deja dos claves vivas.
if grep -q "equipo-${EQUIPO}\$" "$LLAVES" 2>/dev/null; then
    sed -i "/equipo-${EQUIPO}\$/d" "$LLAVES"
    echo "  (tenía una clave anterior: se reemplaza)"
fi

# Dos equipos distintos no pueden compartir puertos
if grep -q "permitlisten=\"${PUERTO_SSH}\"" "$LLAVES" 2>/dev/null; then
    echo "[X] el puerto $PUERTO_SSH ya está asignado a otro equipo. Revísalo antes de seguir."
    exit 1
fi

echo "restrict,port-forwarding,permitlisten=\"${PUERTO_SSH}\",permitlisten=\"${PUERTO_PANTALLA}\" ${CLAVE%% *} ${CLAVE#* } equipo-${EQUIPO}" >> "$LLAVES"
chown tunel:tunel "$LLAVES"; chmod 600 "$LLAVES"

echo "[OK] equipo $EQUIPO · terminal $PUERTO_SSH · pantalla $PUERTO_PANTALLA"
echo "     en la Raspberry:  sudo ./acceso_remoto.sh abrir $PUERTO_SSH $PUERTO_PANTALLA"
