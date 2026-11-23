#!/bin/bash
# Vigilante de parches del flow de Node-RED (nov 2026). Sustituye a instalar_comprimir.sh.
#
# Si alguien actualiza el flow (actualizar_flow.sh, importar desde el editor,
# copiar un flows.json...) y algún parche desaparece, el vigilante lo vuelve a
# poner, todos en una pasada y con un solo reinicio de Node-RED.
#
# Parches disponibles:
#   comprimir          telemetría en lotes de 1 s comprimidos (comprimir_mqtt.py)
#   cola_modbus        una placa muda no deja ciegas a las otras (fix_cola_modbus.py)
#   modbus_resiliente  timeout 500 ms sin reconexión (fix_modbus_resiliente.py)
#
#   sudo ./instalar_parches.sh                      instala con los tres
#   sudo ./instalar_parches.sh comprimir            instala solo con los que se digan
#   sudo ./instalar_parches.sh --quitar             desinstala y quita TODOS los parches
#   sudo ./instalar_parches.sh --quitar cola_modbus quita ese parche y lo saca de la lista
#
# Apagar un parche en un equipo sin desinstalar:  sudo touch /etc/gesinne/sin-<parche>
# Apagar el vigilante entero:                       sudo touch /etc/gesinne/sin-parches
# Lista activa: /etc/gesinne/parches     Registro: journalctl -t gesinne-parches
set -e

[ "$(id -u)" = 0 ] || { echo "Ejecuta con sudo"; exit 1; }

FLOWS=$(ls /home/*/.node-red/flows.json 2>/dev/null | head -1)
[ -n "$FLOWS" ] || { echo "[X] No encuentro ~/.node-red/flows.json"; exit 1; }
NR_USER=$(stat -c %U "$FLOWS")
DIR=$(cd "$(dirname "$0")" && pwd)
TODOS="comprimir cola_modbus modbus_resiliente"

script_de() {
    case "$1" in
        comprimir) echo "$DIR/comprimir_mqtt.py" ;;
        cola_modbus) echo "$DIR/fix_cola_modbus.py" ;;
        modbus_resiliente) echo "$DIR/fix_modbus_resiliente.py" ;;
        *) return 1 ;;
    esac
}

quitar_parche() {
    local s; s=$(script_de "$1") || { echo "[X] parche desconocido: $1"; return 1; }
    if runuser -u "$NR_USER" -- python3 "$s" "$FLOWS" --check >/dev/null 2>&1; then
        runuser -u "$NR_USER" -- python3 "$s" "$FLOWS" --remove >/dev/null
        echo "  [OK] $1 quitado"
        return 0
    fi
    return 2
}

# el vigilante antiguo (solo compresión) se sustituye por este
if [ -f /etc/systemd/system/gesinne-comprimir.path ]; then
    systemctl disable --now gesinne-comprimir.path gesinne-comprimir.timer 2>/dev/null || true
    rm -f /etc/systemd/system/gesinne-comprimir.{path,timer,service} /usr/local/bin/gesinne-comprimir
    systemctl daemon-reload
    echo "  [i] vigilante antiguo gesinne-comprimir sustituido"
fi

mkdir -p /etc/gesinne

if [ "$1" = "--quitar" ]; then
    shift
    if [ $# -eq 0 ]; then
        systemctl disable --now gesinne-parches.path gesinne-parches.timer 2>/dev/null || true
        rm -f /etc/systemd/system/gesinne-parches.{path,timer,service} /usr/local/bin/gesinne-parches /etc/gesinne/parches
        systemctl daemon-reload
        set -- $TODOS
        QUITAR_TODO=1
    fi
    CAMBIO=0
    for p in "$@"; do
        quitar_parche "$p" && CAMBIO=1 || true
        [ -f /etc/gesinne/parches ] && sed -i "/^$p\$/d" /etc/gesinne/parches
    done
    [ $CAMBIO = 1 ] && systemctl restart nodered
    [ -n "$QUITAR_TODO" ] && echo "[OK] Vigilante desinstalado" || echo "[OK] Hecho. Lista activa: $(tr '\n' ' ' < /etc/gesinne/parches 2>/dev/null)"
    exit 0
fi

LISTA="${*:-$TODOS}"
for p in $LISTA; do
    s=$(script_de "$p") || { echo "[X] parche desconocido: $p (hay: $TODOS)"; exit 1; }
    [ -f "$s" ] || { echo "[X] Falta $s (haz git pull)"; exit 1; }
done
printf '%s\n' $LISTA > /etc/gesinne/parches
chmod 644 /etc/gesinne/parches

cat > /usr/local/bin/gesinne-parches <<EOF
#!/bin/bash
# Vuelve a poner los parches de /etc/gesinne/parches que el flow haya perdido.
FLOWS="$FLOWS"
NR_USER="$NR_USER"
DIR="$DIR"
log() { logger -t gesinne-parches "\$*"; }

# una sola pasada a la vez (el .path y el timer pueden saltar juntos)
exec 9>/run/gesinne-parches.lock
flock -w 120 9 || exit 0

[ -f /etc/gesinne/sin-parches ] && exit 0
[ -r /etc/gesinne/parches ] || exit 0
sleep 20                                   # que termine de escribir quien lo esté cambiando
systemctl is-active -q nodered || exit 0   # actualizando (Node-RED parado): ya lo veremos luego

APLICADOS=""
COPIA=""
for p in \$(cat /etc/gesinne/parches); do
    [ -f "/etc/gesinne/sin-\$p" ] && continue
    case "\$p" in
        comprimir) s="\$DIR/comprimir_mqtt.py" ;;
        cola_modbus) s="\$DIR/fix_cola_modbus.py" ;;
        modbus_resiliente) s="\$DIR/fix_modbus_resiliente.py" ;;
        *) log "parche desconocido en la lista: \$p"; continue ;;
    esac
    [ -f "\$s" ] || { log "falta \$s"; continue; }
    runuser -u "\$NR_USER" -- python3 "\$s" "\$FLOWS" --check >/dev/null 2>&1 && continue
    if [ -z "\$COPIA" ]; then
        COPIA="\$FLOWS.antes-parches-\$(date +%Y%m%d-%H%M%S)"
        cp -p "\$FLOWS" "\$COPIA"
    fi
    OUT=\$(runuser -u "\$NR_USER" -- python3 "\$s" "\$FLOWS" --apply 2>&1)
    RC=\$?
    if [ \$RC -eq 0 ] && echo "\$OUT" | grep -q "applied=1"; then
        APLICADOS="\$APLICADOS \$p"
    else
        log "no se pudo aplicar \$p (rc=\$RC): \$(echo "\$OUT" | tail -3 | tr '\n' ' ')"
    fi
done
if [ -n "\$APLICADOS" ]; then
    log "el flow había perdido:\$APLICADOS -> reaplicado y Node-RED reiniciado"
    systemctl restart nodered
fi
# conservar solo las 5 últimas copias
ls -1t "\$FLOWS".antes-parches-* 2>/dev/null | tail -n +6 | xargs -r rm -f
EOF
chmod 755 /usr/local/bin/gesinne-parches

cat > /etc/systemd/system/gesinne-parches.service <<'EOF'
[Unit]
Description=Gesinne: reaplica los parches del flow si se pierden

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gesinne-parches
EOF

cat > /etc/systemd/system/gesinne-parches.path <<EOF
[Unit]
Description=Gesinne: vigila cambios en el flow de Node-RED

[Path]
PathChanged=$FLOWS
Unit=gesinne-parches.service

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/gesinne-parches.timer <<'EOF'
[Unit]
Description=Gesinne: repaso periódico de los parches del flow

[Timer]
OnBootSec=3min
OnUnitActiveSec=30min
Unit=gesinne-parches.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now gesinne-parches.path gesinne-parches.timer
echo "[OK] Vigilante instalado (usuario $NR_USER, $FLOWS)"
echo "     Parches: $LISTA"
echo "     Comprobando ahora (tarda ~20 s)..."
/usr/local/bin/gesinne-parches
FALLOS=0
for p in $LISTA; do
    s=$(script_de "$p")
    if [ -f "/etc/gesinne/sin-$p" ]; then
        echo "  [-] $p apagado en este equipo (/etc/gesinne/sin-$p)"
    elif runuser -u "$NR_USER" -- python3 "$s" "$FLOWS" --check >/dev/null 2>&1; then
        echo "  [OK] $p activo"
    else
        echo "  [!] $p NO está aplicado"; FALLOS=1
    fi
done
[ $FALLOS = 1 ] && echo "  Mira:  journalctl -t gesinne-parches --no-pager | tail"
exit 0
