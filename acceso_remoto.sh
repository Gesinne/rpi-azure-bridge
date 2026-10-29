#!/bin/bash
#
# Acceso remoto bajo demanda: abre un camino hasta esta Raspberry sólo cuando hace
# falta, y lo cierra solo.
#
# Es lo que hacen Tailscale y Raspberry Pi Connect, pero sin ellos y sin gastar datos
# mientras nadie entra: esos dos mantienen una conexión abierta las veinticuatro horas
# contra servidores de terceros. Aquí no hay nada abierto en reposo. La orden de abrir
# llega por el MQTT que la Raspberry YA tiene conectado para enviar la telemetría, así
# que esperar no cuesta ni un byte.
#
# Cuando se abre, la Raspberry llama al servidor (nunca al revés), así que atraviesa el
# NAT del cliente y el CGNAT del operador sin abrir ningún puerto en destino, y funciona
# igual por cable que por SIM.
#
#   acceso_remoto.sh abrir <puerto_terminal> <puerto_pantalla> [minutos]
#   acceso_remoto.sh cerrar
#   acceso_remoto.sh estado
#
# Los puertos los manda el servidor en la orden, no los calcula la Raspberry: hay
# equipos con números altos (el 73001, sin ir más lejos) para los que cualquier
# fórmula del tipo 22000+número se sale del rango válido.
#
set -u

# A qué servidor llamar. Se guarda en el equipo porque quien manda la orden por
# MQTT no se lo pasa: el timbre solo dice "abre", no dónde.
[ -r /etc/gesinne/acceso.conf ] && . /etc/gesinne/acceso.conf

SERVIDOR="${GESINNE_TUNEL_HOST:-acceso.gesinne.cloud}"
PUERTO_SERVIDOR="${GESINNE_TUNEL_PORT:-443}"   # hay redes que filtran el 22 de salida
USUARIO="${GESINNE_TUNEL_USER:-tunel}"
CLAVE="${GESINNE_TUNEL_KEY:-/home/gesinne/.ssh/id_tunel}"
MINUTOS_POR_DEFECTO=30
MINUTOS_MAXIMO=240                     # tope duro: nadie deja esto abierto un fin de semana
RANGO_MIN=30000                        # si el servidor no dice puertos, se reparten aquí
RANGO_MAX=60000
ESTADO=/run/gesinne-acceso-remoto
LOG=/var/log/gesinne-acceso-remoto.log

registra() { echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; echo "$*"; }

numero_equipo() {
  # El mismo fichero del que el bridge saca el s_n que viaja en la telemetría
  local f s
  for f in /home/*/config/equipo_config.json; do
    [ -r "$f" ] || continue
    s=$(python3 -c "import json,sys;print((json.load(open('$f')) or {}).get('serie',''))" 2>/dev/null)
    [ -n "$s" ] && { echo "$s"; return 0; }
  done
  return 1
}

EQUIPO=$(numero_equipo) || { registra "[X] no sé de qué equipo soy: falta equipo_config.json"; exit 1; }
N=$((10#${EQUIPO}))                    # 00017 -> 17, sin que el cero inicial lo haga octal

# De respaldo, por si alguien llama al script a mano sin pasar puertos: se reparten
# dentro de un rango válido y de dos en dos, para que terminal y pantalla del mismo
# equipo vayan juntas y nunca se salgan de los 65535.
HUECO=$(( (N * 2) % (RANGO_MAX - RANGO_MIN) ))
PUERTO_SSH=$((RANGO_MIN + HUECO))
PUERTO_PANTALLA=$((PUERTO_SSH + 1))

vivo() { [ -f "$ESTADO" ] && kill -0 "$(cat "$ESTADO" 2>/dev/null)" 2>/dev/null; }

abrir() {
  # El servidor manda los puertos; si no vienen, se usan los de respaldo
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ] && PUERTO_SSH="$1"
  [[ "${2:-}" =~ ^[0-9]+$ ]] && [ "$2" -ge 1024 ] && [ "$2" -le 65535 ] && PUERTO_PANTALLA="$2"
  local minutos="${3:-$MINUTOS_POR_DEFECTO}"
  [[ "$minutos" =~ ^[0-9]+$ ]] || minutos=$MINUTOS_POR_DEFECTO
  [ "$minutos" -gt "$MINUTOS_MAXIMO" ] && minutos=$MINUTOS_MAXIMO

  if vivo; then
    registra "[=] ya estaba abierto (equipo $EQUIPO, puertos $PUERTO_SSH y $PUERTO_PANTALLA)"
    return 0
  fi

  # Comprobación previa: si la red del cliente filtra el puerto de salida, el ssh se
  # queda vivo reintentando contra una pared y el script daba un OK que no era verdad.
  if ! timeout 6 bash -c "exec 3<>/dev/tcp/${SERVIDOR}/${PUERTO_SERVIDOR}" 2>/dev/null; then
    registra "[X] esta red no deja salir al ${SERVIDOR}:${PUERTO_SERVIDOR} — el túnel no puede abrirse desde aquí"
    return 1
  fi

  # En muchas Raspberry el SSH está parado a propósito; se enciende sólo mientras dura
  # el acceso y se deja como estaba al cerrar.
  if ! systemctl is-active --quiet ssh 2>/dev/null; then
    echo "ssh-estaba-parado" > "${ESTADO}.ssh"
    systemctl start ssh 2>/dev/null || registra "[!] no he podido arrancar el ssh"
  else
    rm -f "${ESTADO}.ssh"
  fi

  # -N: sin shell, sólo el reenvío. Los keepalive son para que el NAT no corte la
  # conexión a mitad de una sesión, no para mantenerla viva en reposo: en reposo no hay
  # túnel ninguno.
  ssh -N -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=60 -o ServerAliveCountMax=3 \
      -i "$CLAVE" -p "$PUERTO_SERVIDOR" \
      -R "${PUERTO_SSH}:localhost:22" \
      -R "${PUERTO_PANTALLA}:localhost:5900" \
      "${USUARIO}@${SERVIDOR}" &
  local pid=$!
  echo "$pid" > "$ESTADO"

  sleep 4
  if ! kill -0 "$pid" 2>/dev/null; then
    registra "[X] el túnel no ha levantado (¿clave rechazada o puerto ocupado en el servidor?)"
    rm -f "$ESTADO"; return 1
  fi
  # Vivo no es suficiente: hay que ver la conexión establecida contra el servidor
  if command -v ss >/dev/null 2>&1 && \
     ! ss -tn state established "dst ${SERVIDOR}" 2>/dev/null | grep -q ":${PUERTO_SERVIDOR}"; then
    registra "[X] el proceso está vivo pero no hay conexión con el servidor: no te fíes, el túnel NO está abierto"
    kill "$pid" 2>/dev/null; rm -f "$ESTADO"; return 1
  fi

  # El cierre automático va aparte y sobrevive a que este script termine: sin esto, un
  # túnel olvidado sí gastaría datos y dejaría la puerta abierta.
  ( sleep $((minutos * 60)); "$0" cerrar >/dev/null 2>&1 ) &
  disown 2>/dev/null || true

  registra "[OK] abierto equipo $EQUIPO · terminal en el puerto $PUERTO_SSH · pantalla en el $PUERTO_PANTALLA · se cierra solo en $minutos min"
}

cerrar() {
  if vivo; then
    kill "$(cat "$ESTADO")" 2>/dev/null
    registra "[OK] cerrado el acceso al equipo $EQUIPO"
  else
    registra "[=] no había nada abierto"
  fi
  rm -f "$ESTADO"
  # Si el ssh estaba parado antes, se deja como estaba
  if [ -f "${ESTADO}.ssh" ]; then
    systemctl stop ssh 2>/dev/null
    rm -f "${ESTADO}.ssh"
  fi
}

estado() {
  if vivo; then
    echo "abierto · equipo $EQUIPO · terminal $PUERTO_SSH · pantalla $PUERTO_PANTALLA"
  else
    echo "cerrado · equipo $EQUIPO"
  fi
}

case "${1:-estado}" in
  abrir)  abrir "${2:-}" "${3:-}" "${4:-}" ;;
  cerrar) cerrar ;;
  estado) estado ;;
  *) echo "uso: $0 {abrir [minutos]|cerrar|estado}"; exit 1 ;;
esac
