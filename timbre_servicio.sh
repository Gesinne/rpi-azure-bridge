#!/bin/bash
#
# Escucha la orden de abrir el acceso remoto a este equipo.
#
# Va aparte de Node-RED a propósito: el flow es de quien lo mantiene y se sobrescribe
# cada vez que se distribuye uno nuevo, así que un cambio nuestro ahí se perdería. Este
# servicio no se pisa con nada y se actualiza con el propio repositorio.
#
# Abre su propia conexión con el broker, que es lo único que cuesta: un latido cada
# cinco minutos, del orden de 70 KB al mes. Comparado con Tailscale o Raspberry Pi
# Connect, que mantienen tráfico constante contra servidores de terceros, no es nada.
#
set -u

BROKER="${GESINNE_MQTT_HOST:-57.129.130.106}"
PUERTO="${GESINNE_MQTT_PORT:-1883}"
TEMA="${GESINNE_TIMBRE_TOPIC:-gesinne/acceso/+}"
LATIDO=300                      # cuanto más alto, menos tráfico; 300 s es seguro con NAT
TIMBRE="$(dirname "$(readlink -f "$0")")/timbre_acceso.py"

[ -x "$TIMBRE" ] || { echo "no encuentro $TIMBRE"; exit 1; }

echo "escuchando $TEMA en $BROKER:$PUERTO"
# Cada mensaje se pasa al verificador, que decide si la orden es legítima. Aquí no se
# valida nada: esto solo oye.
mosquitto_sub -h "$BROKER" -p "$PUERTO" -t "$TEMA" -q 1 -k "$LATIDO" 2>/dev/null |
while IFS= read -r mensaje; do
    [ -n "$mensaje" ] || continue
    printf '%s' "$mensaje" | "$TIMBRE" >/dev/null 2>&1 &
done
