#!/bin/bash
# ============================================================================
#  Informe: kernel, actualizaciones y estado del RS-485. SOLO LECTURA.
#  Uso:  sudo bash diagnostico_sistema_rs485.sh [dias]     (por defecto 12)
#
#  Para cuando un equipo que llevaba meses leyendo bien deja de leer: reune en
#  una pantalla el kernel en uso y los instalados, TODO lo que se actualizo en
#  los ultimos dias (el firmware del bootloader tambien afecta al UART, no solo
#  el kernel), la configuracion real del puerto y una medida en vivo de los
#  errores de trama.
#
#  Lo que hay que buscar: `fe` creciendo = el bus corrompe tramas; `rx` mucho
#  menor que `tx` = las respuestas no vuelven. En un equipo sano fe=0 y rx>>tx.
# ============================================================================
DIAS="${1:-12}"
ln() { echo "  ──────────────────────────────────────────────────────────────"; }

echo ""; echo "  ══ INFORME RS-485 · $(hostname) · $(date '+%d/%m/%Y %H:%M') ══"; echo ""

echo "  [1] KERNEL Y ARRANQUE"; ln
echo "    en uso      : $(uname -r)"
echo "    arrancado el: $(uptime -s)   (hace $(uptime -p 2>/dev/null | sed 's/up //'))"
echo "    el paquete apunta a: $(dpkg -s linux-image-rpi-v8 2>/dev/null | awk '/^Version/{print $2}')"
echo "    modelo      : $(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
echo "    instalados  :"
ls -1 /lib/modules/ 2>/dev/null | grep -v 2712 | sort -V | sed 's/^/        /'
echo ""

echo "  [2] QUE SE ACTUALIZO EN LOS ULTIMOS $DIAS DIAS"; ln
DESDE=$(date -d "-$DIAS days" +%Y-%m-%d 2>/dev/null)
{ zcat /var/log/dpkg.log.*.gz 2>/dev/null; cat /var/log/dpkg.log 2>/dev/null; } \
  | awk -v d="$DESDE" '$1 >= d && ($3=="install" || $3=="upgrade")' \
  | awk '{print $1, $3, $4, $NF}' | sort | sed 's/^/    /' | head -60
echo ""
echo "    de esos, los que pueden tocar el UART:"
{ zcat /var/log/dpkg.log.*.gz 2>/dev/null; cat /var/log/dpkg.log 2>/dev/null; } \
  | awk -v d="$DESDE" '$1 >= d && ($3=="install" || $3=="upgrade")' \
  | grep -iE "linux-image|raspi-firmware|rpi-eeprom|libraspberrypi|device-tree|bootloader|python3-serial|pymodbus" \
  | awk '{print $1, $3, $4, $NF}' | sed 's/^/      >> /'
echo ""
echo "    actualizador automatico: $(systemctl is-enabled unattended-upgrades 2>/dev/null || echo 'no instalado')  |  activo ahora: $(systemctl is-active unattended-upgrades 2>/dev/null)"
echo "    paquetes bloqueados (hold): $(apt-mark showhold 2>/dev/null | tr '\n' ' ')"
echo ""

echo "  [3] EL PUERTO SERIE"; ln
echo "    quien lo tiene abierto:"
lsof /dev/ttyAMA0 2>/dev/null | tail -n +2 | awk '{print "      "$1" (pid "$2")"}' || echo "      nadie"
echo "    mapeo    : $(ls -l /dev/serial0 2>/dev/null | awk '{print $9, $10, $11}')"
echo "    config   : $(stty -F /dev/ttyAMA0 -a 2>/dev/null | head -1)"
echo "    crtscts  : $(stty -F /dev/ttyAMA0 -a 2>/dev/null | tr ' ' '\n' | grep -w -- '-\?crtscts')"
echo "    reloj    : $(cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | awk '/^ *uart /{print $5" Hz"}')"
echo "    dmesg    :"
dmesg 2>/dev/null | grep -iE "pl011|ttyAMA|uart" | tail -6 | sed 's/^/      /'
echo "    otros UART activos (interferencia, ver issue 5578):"
ls /dev/ttyAMA* /dev/ttyS* 2>/dev/null | sed 's/^/      /'
grep -oE "8250.nr_uarts=[0-9]+" /proc/cmdline | sed 's/^/      /'
echo "    DMA declarado en el device tree: $([ -e /proc/device-tree/soc/serial@7e201000/dmas ] && echo SI || echo no)"
echo "    config.txt (lineas relevantes):"
grep -hE "enable_uart|dtoverlay|core_freq|init_uart|dtparam" /boot/firmware/config.txt /boot/config.txt 2>/dev/null | sed 's/^/      /'
echo ""

echo "  [4] ERRORES DE TRAMA EN VIVO (60 s)"; ln
leer() { cat /proc/tty/driver/ttyAMA 2>/dev/null | grep '^0:'; }
A=$(leer); echo "    antes : $A"
sleep 60
B=$(leer); echo "    despues: $B"
v() { echo "$1" | grep -oE "$2:[0-9]+" | cut -d: -f2; }
for c in tx rx fe oe brk; do
    a=$(v "$A" $c); b=$(v "$B" $c)
    [ -z "$a" ] && continue
    printf "    %-4s +%s\n" "$c" "$((b-a))"
done
echo ""
ln
echo "    COMO LEERLO:"
echo "    - fe sube        -> el bus corrompe tramas: medio fisico o driver"
echo "    - rx mucho < tx  -> las preguntas salen y las respuestas no vuelven"
echo "    - tx no sube     -> nadie esta preguntando (Node-RED parado?)"
echo "    - oe sube        -> el driver no lee el FIFO a tiempo (latencia)"
echo "    - brk sube       -> alguien mantiene la linea a nivel bajo (transceptor)"
ln; echo ""
