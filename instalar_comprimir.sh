#!/bin/bash
# OBSOLETO (nov 2026): usar instalar_parches.sh, que incluye la compresión y lo sustituye al instalarse.
# Instala el vigilante de la telemetría comprimida (nov 2026).
#
# Si alguien actualiza el flow (actualizar_flow.sh, importar desde el editor,
# copiar un flows.json...) y el nodo "Comprimir lote 1 s" desaparece, el
# vigilante lo vuelve a poner y reinicia Node-RED. Ver comprimir_mqtt.py.
#
#   sudo ./instalar_comprimir.sh            instala y aplica ya
#   sudo ./instalar_comprimir.sh --quitar   desinstala el vigilante y quita el parche
#
# Para que NO lo vuelva a poner en un equipo sin desinstalar:
#   sudo touch /etc/gesinne/sin-comprimir
#
# Cada reaplicación queda en el journal:  journalctl -t gesinne-comprimir
set -e

[ "$(id -u)" = 0 ] || { echo "Ejecuta con sudo"; exit 1; }

FLOWS=$(ls /home/*/.node-red/flows.json 2>/dev/null | head -1)
[ -n "$FLOWS" ] || { echo "[X] No encuentro ~/.node-red/flows.json"; exit 1; }
NR_USER=$(stat -c %U "$FLOWS")
DIR=$(cd "$(dirname "$0")" && pwd)
PATCHER="$DIR/comprimir_mqtt.py"
[ -f "$PATCHER" ] || { echo "[X] Falta $PATCHER"; exit 1; }

if [ "$1" = "--quitar" ]; then
    systemctl disable --now gesinne-comprimir.path gesinne-comprimir.timer 2>/dev/null || true
    rm -f /etc/systemd/system/gesinne-comprimir.{path,timer,service} /usr/local/bin/gesinne-comprimir
    systemctl daemon-reload
    if runuser -u "$NR_USER" -- python3 "$PATCHER" "$FLOWS" --check; then
        runuser -u "$NR_USER" -- python3 "$PATCHER" "$FLOWS" --remove
        systemctl restart nodered
    fi
    echo "[OK] Vigilante desinstalado y parche quitado"
    exit 0
fi

mkdir -p /etc/gesinne

cat > /usr/local/bin/gesinne-comprimir <<EOF
#!/bin/bash
# Vuelve a poner "Comprimir lote 1 s" si el flow lo ha perdido.
FLOWS="$FLOWS"
NR_USER="$NR_USER"
PATCHER="$PATCHER"
log() { logger -t gesinne-comprimir "\$*"; }

# una sola pasada a la vez (el .path y el timer pueden saltar juntos)
exec 9>/run/gesinne-comprimir.lock
flock -w 120 9 || exit 0

[ -f /etc/gesinne/sin-comprimir ] && exit 0
[ -f "\$PATCHER" ] || { log "falta \$PATCHER"; exit 0; }
sleep 20                                   # que termine de escribir quien lo esté cambiando
systemctl is-active -q nodered || exit 0   # actualizando (Node-RED parado): ya lo veremos luego
runuser -u "\$NR_USER" -- python3 "\$PATCHER" "\$FLOWS" --check && exit 0

cp -p "\$FLOWS" "\$FLOWS.antes-comprimir-\$(date +%Y%m%d-%H%M%S)"
OUT=\$(runuser -u "\$NR_USER" -- python3 "\$PATCHER" "\$FLOWS" --apply 2>&1)
RC=\$?
if [ \$RC -eq 0 ] && echo "\$OUT" | grep -q "applied=1"; then
    log "el flow había perdido la compresión: reaplicada y Node-RED reiniciado"
    systemctl restart nodered
else
    log "no se pudo reaplicar (rc=\$RC): \$OUT"
fi
# conservar solo las 5 últimas copias
ls -1t "\$FLOWS".antes-comprimir-* 2>/dev/null | tail -n +6 | xargs -r rm -f
EOF
chmod 755 /usr/local/bin/gesinne-comprimir

cat > /etc/systemd/system/gesinne-comprimir.service <<'EOF'
[Unit]
Description=Gesinne: reaplica la telemetría comprimida si el flow la pierde

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gesinne-comprimir
EOF

cat > /etc/systemd/system/gesinne-comprimir.path <<EOF
[Unit]
Description=Gesinne: vigila cambios en el flow de Node-RED

[Path]
PathChanged=$FLOWS
Unit=gesinne-comprimir.service

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/gesinne-comprimir.timer <<'EOF'
[Unit]
Description=Gesinne: repaso periódico de la telemetría comprimida

[Timer]
OnBootSec=3min
OnUnitActiveSec=30min
Unit=gesinne-comprimir.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now gesinne-comprimir.path gesinne-comprimir.timer
echo "[OK] Vigilante instalado (usuario $NR_USER, $FLOWS)"
echo "     Comprobando ahora..."
/usr/local/bin/gesinne-comprimir
if runuser -u "$NR_USER" -- python3 "$PATCHER" "$FLOWS" --check; then
    echo "[OK] Compresión activa"
else
    echo "[!] No está aplicada: mira  journalctl -t gesinne-comprimir"
fi
