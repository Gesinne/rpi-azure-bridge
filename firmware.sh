#!/bin/bash
# ============================================
# Gesinne - Actualizador de Firmware Placas
# ============================================

# Colores y formato
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuración serie
SERIAL_PORT="/dev/ttyAMA0"
BAUDRATE=115200
DELAY_MS=150

# Directorio temporal para firmwares
FW_DIR="/tmp/gesinne-firmware"
CACHE_DIR="/opt/nodered-flows-cache"
CREDS_FILE="/opt/nodered-flows-cache/.git_credentials"

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [*] Gesinne - Actualizador de Firmware"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Verificar root
if [ "$EUID" -ne 0 ]; then
    echo "  [X] ERROR: Ejecutar con sudo"
    exit 1
fi

# Verificar puerto serie
if [ ! -e "$SERIAL_PORT" ]; then
    echo "  [X] ERROR: Puerto serie $SERIAL_PORT no encontrado"
    exit 1
fi

# Verificar pyserial
if ! python3 -c "import serial" 2>/dev/null; then
    echo "  [!] Instalando pyserial..."
    pip3 install pyserial -q
fi

# Función para enviar comando y leer respuesta
send_command() {
    local cmd="$1"
    local wait_time="${2:-1}"
    python3 << EOF
import serial
import time

try:
    ser = serial.Serial('$SERIAL_PORT', $BAUDRATE, timeout=2, xonxoff=True)
    time.sleep(0.1)
    ser.write(b'$cmd\r\n')
    time.sleep($wait_time)
    response = ser.read(ser.in_waiting or 1000).decode('latin-1', errors='ignore')
    ser.close()
    print(response)
except Exception as e:
    print(f'ERROR: {e}')
EOF
}

# Función para enviar archivo .S línea a línea
send_firmware_file() {
    local file="$1"
    python3 << EOF
import serial
import time
import sys

try:
    ser = serial.Serial('$SERIAL_PORT', $BAUDRATE, timeout=2, xonxoff=True)
    
    with open('$file', 'r') as f:
        lines = f.readlines()
    
    total = len(lines)
    print(f'  Enviando {total} lineas...')
    
    for i, line in enumerate(lines):
        line = line.strip()
        if line:
            ser.write((line + '\r\n').encode())
            time.sleep($DELAY_MS / 1000.0)
        
        # Mostrar progreso cada 100 lineas
        if (i + 1) % 100 == 0 or (i + 1) == total:
            pct = int((i + 1) * 100 / total)
            print(f'\r  Progreso: {i+1}/{total} ({pct}%)', end='', flush=True)
    
    print('')
    time.sleep(1)
    response = ser.read(ser.in_waiting or 1000).decode('latin-1', errors='ignore')
    ser.close()
    print('  [OK] Firmware enviado')
    if response:
        print(f'  Respuesta: {response[:200]}')
except Exception as e:
    print(f'  [X] ERROR: {e}')
    sys.exit(1)
EOF
}

# Obtener credenciales de GitHub
get_credentials() {
    if [ -f "$CREDS_FILE" ]; then
        source "$CREDS_FILE"
        echo "  [K] Usando credenciales guardadas (usuario: $GIT_USER)"
        read -p "  ¿Usar estas credenciales? [S/n]: " USE_SAVED
        if [ "$USE_SAVED" = "n" ] || [ "$USE_SAVED" = "N" ]; then
            GIT_USER=""
            GIT_TOKEN=""
        fi
    fi
    
    if [ -z "$GIT_USER" ] || [ -z "$GIT_TOKEN" ]; then
        echo "  [K] Credenciales de GitHub"
        read -p "  Usuario: " GIT_USER
        read -s -p "  Token: " GIT_TOKEN
        echo ""
    fi
}

# Descargar firmwares desde GitHub
download_firmwares() {
    get_credentials
    
    NODERED_REPO="https://${GIT_USER}:${GIT_TOKEN}@github.com/Gesinne/NODERED.git"
    
    echo ""
    echo "  [v] Descargando firmwares..."
    
    rm -rf "$FW_DIR"
    mkdir -p "$FW_DIR"
    
    # Clonar solo la carpeta FW (sparse checkout)
    cd "$FW_DIR"
    git init -q
    git remote add origin "$NODERED_REPO"
    git config core.sparseCheckout true
    echo "FW/" > .git/info/sparse-checkout
    
    if git pull -q origin main 2>/dev/null || git pull -q origin master 2>/dev/null; then
        echo "  [OK] Firmwares descargados"
        return 0
    else
        echo "  [X] Error descargando firmwares"
        return 1
    fi
}

# Listar versiones disponibles
list_versions() {
    if [ ! -d "$FW_DIR/FW" ]; then
        echo "  [X] No hay firmwares descargados"
        return 1
    fi
    
    echo ""
    echo "  Versiones disponibles:"
    echo ""
    
    i=1
    declare -g -a VERSION_ARRAY
    for dir in $(ls -d "$FW_DIR/FW/v"* 2>/dev/null | sort -V -r); do
        version=$(basename "$dir")
        VERSION_ARRAY[$i]="$version"
        echo "    $i) $version"
        i=$((i+1))
        if [ $i -gt 5 ]; then
            break
        fi
    done
    
    if [ $i -eq 1 ]; then
        echo "  [X] No se encontraron versiones"
        return 1
    fi
    
    return 0
}

# Detectar tipo de micro
detect_micro() {
    echo ""
    echo "  [~] Detectando tipo de micro..."
    echo ""
    
    response=$(send_command "?MP" 2)
    
    if echo "$response" | grep -q "646"; then
        MICRO_TYPE="646"
        echo "  [OK] Micro detectado: MC56F82646"
        return 0
    elif echo "$response" | grep -q "789"; then
        MICRO_TYPE="789"
        echo "  [OK] Micro detectado: MC56F84789"
        return 0
    else
        echo "  [!] No se pudo detectar el micro"
        echo "  Respuesta: $response"
        echo ""
        echo "  Selecciona manualmente:"
        echo "    1) MC56F82646"
        echo "    2) MC56F84789"
        read -p "  Opcion: " MICRO_CHOICE
        case "$MICRO_CHOICE" in
            1) MICRO_TYPE="646" ;;
            2) MICRO_TYPE="789" ;;
            *) return 1 ;;
        esac
        return 0
    fi
}

# Proceso de actualización de una placa
update_board() {
    local board_name="$1"
    local fw_file="$2"
    
    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Actualizando $board_name"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  [!] Conecta el cable serie a la placa $board_name"
    echo ""
    read -p "  Pulsa ENTER cuando este conectado..." dummy
    
    # Detectar micro
    if ! detect_micro; then
        echo "  [X] Error detectando micro"
        return 1
    fi
    
    # Seleccionar archivo correcto
    if [ "$MICRO_TYPE" = "646" ]; then
        FW_FILE=$(find "$FW_DIR/FW/$SELECTED_VERSION" -name "*646*.S" -o -name "*646*.s" 2>/dev/null | head -1)
    else
        FW_FILE=$(find "$FW_DIR/FW/$SELECTED_VERSION" -name "*789*.S" -o -name "*789*.s" 2>/dev/null | head -1)
    fi
    
    if [ -z "$FW_FILE" ] || [ ! -f "$FW_FILE" ]; then
        echo "  [X] No se encontro firmware para micro $MICRO_TYPE"
        return 1
    fi
    
    echo "  [i] Archivo: $(basename "$FW_FILE")"
    echo ""
    
    # Poner en estado E0
    echo "  [~] Enviando ?E0..."
    send_command "?E0" 1 > /dev/null
    sleep 1
    
    # Entrar en bootloader
    echo "  [~] Enviando ?BL (bootloader)..."
    response=$(send_command "?BL" 2)
    
    if [ "$MICRO_TYPE" = "789" ]; then
        echo ""
        echo "  [!] MICRO 789 DETECTADO"
        echo "  [!] Baja el interruptor de electronica para reiniciar la placa"
        echo ""
        read -p "  Pulsa ENTER cuando hayas reiniciado..." dummy
    fi
    
    # Esperar mensaje bootloader
    echo "  [~] Esperando bootloader..."
    sleep 2
    
    # Verificar que estamos en bootloader
    response=$(python3 -c "
import serial
import time
ser = serial.Serial('$SERIAL_PORT', $BAUDRATE, timeout=3, xonxoff=True)
time.sleep(1)
data = ser.read(ser.in_waiting or 500).decode('latin-1', errors='ignore')
ser.close()
print(data)
" 2>/dev/null)
    
    if echo "$response" | grep -qi "bootloader\|cesinel\|ready"; then
        echo "  [OK] Bootloader activo"
    else
        echo "  [!] Respuesta: $response"
        read -p "  ¿Continuar de todos modos? [s/N]: " CONTINUE
        if [ "$CONTINUE" != "s" ] && [ "$CONTINUE" != "S" ]; then
            return 1
        fi
    fi
    
    # Enviar firmware
    echo ""
    echo "  [~] Enviando firmware..."
    send_firmware_file "$FW_FILE"
    
    echo ""
    echo "  [OK] Placa $board_name actualizada"
    return 0
}

# Menu principal
main_menu() {
    while true; do
        echo ""
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Menu Firmware"
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  1) Descargar firmwares de GitHub"
        echo "  2) Actualizar placa individual"
        echo "  3) Actualizar L1, L2, L3 (guiado)"
        echo "  4) Detectar micro conectado"
        echo "  5) Enviar comando manual"
        echo "  0) Salir"
        echo ""
        read -p "  Opcion [0-5]: " OPTION
        
        case "$OPTION" in
            1)
                download_firmwares
                ;;
            2)
                if [ ! -d "$FW_DIR/FW" ]; then
                    echo "  [!] Primero descarga los firmwares (opcion 1)"
                    continue
                fi
                
                if ! list_versions; then
                    continue
                fi
                
                echo ""
                read -p "  Selecciona version: " VER_CHOICE
                SELECTED_VERSION="${VERSION_ARRAY[$VER_CHOICE]}"
                
                if [ -z "$SELECTED_VERSION" ]; then
                    echo "  [X] Version no valida"
                    continue
                fi
                
                echo ""
                read -p "  Nombre de la placa (ej: L1): " BOARD_NAME
                update_board "$BOARD_NAME" ""
                ;;
            3)
                if [ ! -d "$FW_DIR/FW" ]; then
                    echo "  [!] Primero descarga los firmwares (opcion 1)"
                    continue
                fi
                
                if ! list_versions; then
                    continue
                fi
                
                echo ""
                read -p "  Selecciona version: " VER_CHOICE
                SELECTED_VERSION="${VERSION_ARRAY[$VER_CHOICE]}"
                
                if [ -z "$SELECTED_VERSION" ]; then
                    echo "  [X] Version no valida"
                    continue
                fi
                
                echo ""
                echo "  [i] Actualizacion guiada L1, L2, L3"
                echo "  [i] Version: $SELECTED_VERSION"
                echo ""
                
                for board in L1 L2 L3; do
                    read -p "  ¿Actualizar $board? [S/n]: " DO_BOARD
                    if [ "$DO_BOARD" != "n" ] && [ "$DO_BOARD" != "N" ]; then
                        update_board "$board" ""
                    fi
                done
                
                echo ""
                echo "  [OK] Proceso completado"
                ;;
            4)
                echo ""
                echo "  [!] Asegurate de que el cable esta conectado"
                read -p "  Pulsa ENTER para continuar..." dummy
                detect_micro
                ;;
            5)
                echo ""
                read -p "  Comando (sin ?): " CMD
                echo ""
                echo "  [~] Enviando ?$CMD..."
                response=$(send_command "?$CMD" 2)
                echo "  Respuesta:"
                echo "$response" | head -20
                ;;
            0)
                echo ""
                echo "  [B] Hasta luego!"
                exit 0
                ;;
            *)
                echo "  [X] Opcion no valida"
                ;;
        esac
    done
}

# Ejecutar menu
main_menu
