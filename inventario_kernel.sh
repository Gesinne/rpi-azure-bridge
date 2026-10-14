#!/bin/bash
# ============================================================================
#  Inventario de kernel y salud del bus RS-485 de todo el parque. SOLO LECTURA.
#
#  POR QUE: el salto a Debian 13 (kernel 6.18) parece romper el Modbus. El
#  paquete del firmware esta descartado (misma version en sano y rotos), pero el
#  BOOTLOADER GRABADO en la EEPROM si difiere: 2025/11/05 en el sano frente a
#  2026/05/17 en el roto. Y eso inicializa los pines y los relojes antes de Linux,
#  asi que hay que inventariar las dos cosas: sistema/kernel y bootloader. Medido el
#  14-oct-2026 con los contadores del propio driver del UART:
#     00142 (6.12.109): tx 1.455.968  rx 24.518.839  fe 0      <- sano
#     00128 (6.18.50):  tx   109.792  rx     10.571  fe 598
#     00152 (6.18.50):  tx    64.288  rx      6.792  fe 507
#  En un equipo sano `rx` es MUCHO mayor que `tx` (cada pregunta devuelve una
#  respuesta larga) y `fe` —errores de trama— es CERO. Este barrido saca esos
#  numeros de cada RPi para ver si la correlacion se sostiene en todo el parque
#  y, sobre todo, para saber que equipos van a caer: los que tengan un 6.18
#  instalado y aun no hayan reiniciado.
#
#  No escribe nada, no para servicios, no toca el flow. Solo lee.
#
#  Uso:
#     ./inventario_kernel.sh rpis.csv            # fichero: ip,equipo,cliente,estado
#     ./inventario_kernel.sh rpis.csv 20         # 20 en paralelo (por defecto 10)
#  Hay que lanzarlo desde donde haya VPN a 10.10.16/17 y con la llave SSH puesta.
# ============================================================================
LISTA="${1:?uso: $0 <fichero ip,equipo,cliente> [paralelas]}"
PAR="${2:-10}"
USUARIO="${SSH_USER:-gesinne}"

uno() {
    IFS=, read -r ip equipo cliente estado <<< "$1"
    [ -z "$ip" ] && return
    out=$(timeout 25 ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
          -o ConnectTimeout=6 -o LogLevel=ERROR "$USUARIO@$ip" '
        K=$(uname -r)
        D=$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-?}")
        # lo GRABADO en la EEPROM, que no es lo mismo que la version del paquete
        B=$(vcgencmd bootloader_version 2>/dev/null | head -1 | cut -d' ' -f1)
        U=$(uptime -s 2>/dev/null)
        T=$(cat /proc/tty/driver/ttyAMA 2>/dev/null | grep "^0:")
        TX=$(echo "$T" | grep -oE "tx:[0-9]+" | cut -d: -f2)
        RX=$(echo "$T" | grep -oE "rx:[0-9]+" | cut -d: -f2)
        FE=$(echo "$T" | grep -oE "fe:[0-9]+" | cut -d: -f2)
        # kernels instalados pero aun no arrancados = equipos que caeran al reiniciar
        PEND=$(ls -d /lib/modules/*/ 2>/dev/null | sed "s|/lib/modules/||;s|/||" | grep -c "^6\.18")
        echo "$K|${U:-?}|${TX:-0}|${RX:-0}|${FE:-0}|$PEND|deb${D}|${B:-?}"' 2>/dev/null)
    if [ -z "$out" ]; then
        printf "  %-15s %-7s %-20s %s\n" "$ip" "$equipo" "${cliente:0:20}" "SIN ACCESO"
        return
    fi
    IFS='|' read -r k u tx rx fe pend deb boot <<< "$out"
    ratio="-"
    [ "${tx:-0}" -gt 0 ] 2>/dev/null && ratio=$(awk "BEGIN{printf \"%.1f\", $rx/$tx}")
    veredicto="ok"
    [ "${fe:-0}" -gt 0 ] 2>/dev/null && veredicto="ERRORES fe=$fe"
    awk "BEGIN{exit !($ratio < 1)}" 2>/dev/null && [ "$ratio" != "-" ] && veredicto="BUS ROTO (rx<tx) fe=$fe"
    printf "  %-15s %-7s %-18s %-7s %-18s %-11s ratio=%-6s %s\n" \
           "$ip" "$equipo" "${cliente:0:18}" "$deb" "$k" "$boot" "$ratio" "$veredicto"
}
export -f uno
export USUARIO

echo ""
echo "  IP              EQUIPO  CLIENTE            DEBIAN  KERNEL             BOOTLOADER  rx/tx    VEREDICTO"
echo "  ---------------------------------------------------------------------------------------------"
grep -vE "^\s*#|^\s*$" "$LISTA" | xargs -P "$PAR" -I{} bash -c 'uno "{}"'
echo ""
echo "  rx/tx < 1 o fe > 0  ->  el bus pierde tramas. En un equipo sano rx/tx es ~17 y fe=0."
echo ""
