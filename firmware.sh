#!/bin/bash
# ============================================
# Gesinne - Verificacion de Parametros Placas
# ============================================

# Configuración serie
SERIAL_PORT="/dev/ttyAMA0"
BAUDRATE=115200

# Verificar root
if [ "$EUID" -ne 0 ]; then
    echo "  [X] ERROR: Ejecutar con sudo"
    exit 1
fi

# Función para verificar parametrización
verificar_parametrizacion() {
    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Verificar parametrizacion de placas"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  [!]  Parando Node-RED temporalmente..."
    
    # Parar Node-RED
    sudo systemctl stop nodered 2>/dev/null
    docker stop gesinne-rpi >/dev/null 2>&1 || true
    sleep 2
    echo "  [OK] Servicios parados"
    echo ""
    echo "  [M] Leyendo las 3 tarjetas..."
    echo ""
    
    python3 << 'EOFVERIF'
import sys
try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    try:
        from pymodbus.client.sync import ModbusSerialClient
    except ImportError:
        print("  [X] pymodbus no instalado")
        sys.exit(1)

import time

client = ModbusSerialClient(
    port='/dev/ttyAMA0',
    baudrate=115200,
    bytesize=8,
    parity='N',
    stopbits=1,
    timeout=1
)

if not client.connect():
    print("  [X] No se pudo conectar al puerto serie")
    sys.exit(1)

# Definir parametros a verificar con sus registros y rangos correctos
# Formato: registro: (nombre, valor_min, valor_max, valores_exactos)
# Si valores_exactos no es None, se usa en lugar de min/max
PARAMS_CHECK = {
    55: ("estado_inicial", None, None, [0, 2]),
    56: ("tension_consigna", 1760, 2640, None),
    63: ("angulo_tension_cargas_altas", 179, 179, None),
    64: ("angulo_tension_cargas_bajas", 179, 179, None),
    5:  ("frecuencia", 4900, 5100, None),
    57: ("temperatura_admisible", 0, 600, None),
    47: ("dead_time", 3, 22, None),
    48: ("direccion_modbus", None, None, [1, 2, 3]),
    66: ("sensibilidad_transitorios", 0, 4, None),
    61: ("velocidad_modbus", 0, 2, None),
    46: ("topologia", 0, 4, None),
    60: ("tipo_alimentacion", None, None, [0, 1]),
    62: ("empaquetado_transistores", None, None, [0, 1]),
    44: ("tension_primario_trafo", 0, 3600, None),
}

# Leer las 3 placas
data_all = {}
for unit_id in [1, 2, 3]:
    fase = {1: "L1", 2: "L2", 3: "L3"}[unit_id]
    print(f"  [M] Leyendo tarjeta {fase}...", end=" ", flush=True)
    
    data = []
    max_retries = 3
    for retry in range(max_retries):
        data = []
        success = True
        for start in range(0, 96, 40):
            count = min(40, 96 - start)
            result = client.read_holding_registers(address=start, count=count, slave=unit_id)
            if result.isError():
                success = False
                break
            data.extend(result.registers)
        
        if success and len(data) >= 70:
            print("[OK]")
            break
        else:
            if retry < max_retries - 1:
                print(f"[!] reintentando ({retry+2}/{max_retries})...", end=" ", flush=True)
                time.sleep(1)
            else:
                print("[X] sin respuesta")
    
    data_all[unit_id] = data if len(data) >= 70 else None

client.close()

# Verificar parametros
print("")
print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("  RESULTADO DE VERIFICACION")
print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("")

total_problemas = 0
for unit_id in [1, 2, 3]:
    fase = {1: "L1", 2: "L2", 3: "L3"}[unit_id]
    data = data_all[unit_id]
    
    if data is None:
        print(f"  [{fase}] [X] No se pudo leer la placa")
        print("")
        continue
    
    problemas = []
    for reg, (nombre, val_min, val_max, valores_exactos) in PARAMS_CHECK.items():
        if reg >= len(data):
            continue
        
        valor = data[reg]
        
        # Verificar si el valor es correcto
        es_correcto = False
        if valores_exactos is not None:
            es_correcto = valor in valores_exactos
            rango_str = f"debe ser {valores_exactos}"
        else:
            es_correcto = val_min <= valor <= val_max
            if val_min == val_max:
                rango_str = f"debe ser {val_min}"
            else:
                rango_str = f"debe ser {val_min}-{val_max}"
        
        if not es_correcto:
            problemas.append(f"{nombre}={valor} ({rango_str})")
    
    if problemas:
        print(f"  [{fase}] [!] DESPARAMETRIZADA - {len(problemas)} problema(s):")
        for p in problemas:
            print(f"       - {p}")
        total_problemas += len(problemas)
    else:
        print(f"  [{fase}] [OK] Parametros correctos")
    print("")

# Resumen
print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
if total_problemas == 0:
    print("  [OK] TODAS LAS PLACAS CORRECTAMENTE PARAMETRIZADAS")
else:
    print(f"  [!] {total_problemas} PARAMETRO(S) INCORRECTO(S) DETECTADO(S)")
print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
EOFVERIF
    
    echo ""
    echo "  [~] Reiniciando Node-RED..."
    sudo systemctl start nodered
    sleep 3
    echo "  [OK] Node-RED reiniciado"
}

# Si se llama con argumento "verificar", ejecutar directamente
if [ "$1" = "verificar" ]; then
    verificar_parametrizacion
    exit 0
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
