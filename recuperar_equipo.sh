#!/bin/bash
#
# Qué hacer en el rato en que un equipo caído vuelve a estar accesible.
#
# Un equipo que se queda mudo suele volver con un ciclo de alimentación, y entonces se
# abre una ventana que puede durar poco: si la causa sigue ahí, se vuelve a caer. Este
# guion aprovecha esa ventana para dos cosas, en este orden:
#
#   1. averiguar POR QUÉ se cayó, mientras las pruebas todavía están en el equipo
#      (el journal del arranque anterior se pierde en el siguiente reinicio),
#   2. y dejar puesto el acceso remoto, para que la próxima vez no dependamos de que
#      alguien tenga el router a mano.
#
# Primero se mira y luego se toca: si se limpia el disco antes de ver qué lo llenó,
# se pierde la única prueba de qué pasó.
#
#   sudo ./recuperar_equipo.sh                 → solo mira y cuenta
#   sudo ./recuperar_equipo.sh --limpiar       → además libera disco si está lleno
#   sudo GESINNE_MQTT_USER=timbre GESINNE_MQTT_PASS=... \
#        ./recuperar_equipo.sh --timbre        → además deja puesto el acceso remoto
#
set -u
[ "$(id -u)" = "0" ] || { echo "Ejecútalo con sudo."; exit 1; }

DIR="$(dirname "$(readlink -f "$0")")"
LIMPIAR=0; TIMBRE=0
for a in "$@"; do
    case "$a" in
        --limpiar) LIMPIAR=1 ;;
        --timbre)  TIMBRE=1 ;;
        *) echo "no entiendo '$a'"; exit 1 ;;
    esac
done

titulo() { echo; echo "── $* ──────────────────────────────────────────"; }

titulo "1. Cuánto lleva en pie"
uptime -p 2>/dev/null
echo "arrancó: $(uptime -s 2>/dev/null)"
echo "ahora:   $(date '+%F %T')"

titulo "2. Disco"
df -h / /var 2>/dev/null | sed 's/^/  /'
USO=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')
if [ "${USO:-0}" -ge 90 ]; then
    echo "  [!] la raíz está al ${USO}%: con el disco lleno no arrancan ni Docker ni Node-RED."
    echo "  lo que más ocupa:"
    du -xh / 2>/dev/null | sort -rh | head -12 | sed 's/^/     /'
else
    echo "  disco correcto (${USO}%): no es la causa."
fi

titulo "3. Qué dice el kernel (alimentación y tarjeta)"
# Tres cosas tumban una Raspberry en un cuadro: la fuente, la SD y el calor. Las tres
# dejan rastro aquí, y el rastro se borra al siguiente arranque.
dmesg 2>/dev/null | grep -iE "under-voltage|voltage normalised|mmc[0-9]|I/O error|EXT4-fs error|remounting.*read-only|Out of memory" \
    | tail -20 | sed 's/^/  /' || echo "  (nada relevante)"
echo "  --- arranque anterior ---"
journalctl -b -1 -p err --no-pager 2>/dev/null | tail -15 | sed 's/^/  /' || echo "  (no se guarda el arranque anterior)"

titulo "4. Servicios"
for s in nodered node-red docker mosquitto gesinne-timbre ssh; do
    E=$(systemctl is-active "$s" 2>/dev/null)
    [ "$E" = "inactive" ] && systemctl list-unit-files "$s.service" >/dev/null 2>&1 || true
    [ -n "$E" ] && [ "$E" != "unknown" ] && printf '  %-18s %s\n' "$s" "$E"
done
command -v docker >/dev/null && { echo "  contenedores:"; docker ps -a --format '    {{.Names}}  {{.Status}}' 2>/dev/null; }

titulo "5. Está enviando dato ahora"
ss -ltnp 2>/dev/null | grep -E ':(22|1880|1883|8080) ' | sed 's/^/  /' || echo "  ningún puerto nuestro escuchando"
curl -s --max-time 5 http://localhost:8080/health 2>/dev/null | sed 's/^/  /' || echo "  el bridge no responde en el 8080"

if [ "$LIMPIAR" = "1" ] && [ "${USO:-0}" -ge 90 ]; then
    titulo "6. Liberando disco"
    # Lo que se puede borrar sin pensarlo: registros viejos e imágenes que ya no usa nadie.
    journalctl --vacuum-time=3d 2>/dev/null | tail -2 | sed 's/^/  /'
    command -v docker >/dev/null && docker image prune -af 2>/dev/null | tail -2 | sed 's/^/  /'
    apt-get clean 2>/dev/null
    df -h / | tail -1 | sed 's/^/  ahora: /'
fi

if [ "$TIMBRE" = "1" ]; then
    titulo "7. Acceso remoto para la próxima vez"
    if [ -x "$DIR/instalar_timbre.sh" ]; then
        GESINNE_TUNEL_HOST="${GESINNE_TUNEL_HOST:-acceso.gesinne.cloud}" \
        GESINNE_TUNEL_PORT="${GESINNE_TUNEL_PORT:-443}" \
        GESINNE_CLAVE_SERVIDOR="${GESINNE_CLAVE_SERVIDOR:-}" \
        "$DIR/instalar_timbre.sh"
    else
        echo "  no encuentro instalar_timbre.sh en $DIR"
    fi
    echo
    echo "  Y Raspberry Pi Connect, que hay que hacer a mano porque pide autorizar en el"
    echo "  navegador (el subcomando es signin, NO login):"
    echo "     rpi-connect signin     → abre la URL que dé y autoriza"
    echo "     loginctl enable-linger \$SUDO_USER"
    echo "     rpi-connect on && rpi-connect shell on"
fi

titulo "Resumen"
echo "  Manda estas dos líneas para dar de alta el equipo en el servidor de acceso:"
[ -s /etc/gesinne/timbre.key ] && echo "    secreto: $(cat /etc/gesinne/timbre.key)" || echo "    (sin secreto: lánzalo con --timbre)"
[ -s "/home/${SUDO_USER:-gesinne}/.ssh/id_tunel.pub" ] && echo "    clave:   $(cat "/home/${SUDO_USER:-gesinne}/.ssh/id_tunel.pub")"
