#!/bin/bash
# ============================================
# Gesinne - Verificacion de Parametros Placas
# ============================================

# Configuración serie
SERIAL_PORT="/dev/ttyAMA0"
# El bootloader del firmware (flujo XMODEM) usa 115200 fijo: NO TOCAR.
# Para Modbus en runtime, los scripts Python embebidos importan modbus_helper.py
# que autodetecta el baudrate de la placa (registro 47/61). Si el helper no está
# disponible (instalaciones antiguas), se usa BAUDRATE como fallback.
BAUDRATE=115200

# Directorio del repo: lo necesitan los scripts Python embebidos para
# localizar modbus_helper.py.
export RPI_BRIDGE_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

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
import sys, os
try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    try:
        from pymodbus.client.sync import ModbusSerialClient
    except ImportError:
        print("  [X] pymodbus no instalado")
        sys.exit(1)

import time

# Cliente Modbus: prefiere helper con autodetección de baudrate; fallback 115200.
sys.path.insert(0, os.environ.get('RPI_BRIDGE_DIR', '.'))
try:
    from modbus_helper import open_modbus_client
    client = open_modbus_client(port='/dev/ttyAMA0', timeout=1)
except ImportError:
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

# Función para reparar placas corruptas
reparar_placas() {
    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Reparar placas desparametrizadas"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  [!]  Parando Node-RED para leer registros..."
    sudo systemctl stop nodered 2>/dev/null
    docker stop gesinne-rpi >/dev/null 2>&1 || true
    sleep 2
    echo "  [OK] Servicios parados"
    echo ""
    echo "  [M] Leyendo valores actuales de las 3 placas..."
    echo ""
    
    # Leer y mostrar valores actuales
    python3 << 'EOFLEER'
import sys, os
try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    try:
        from pymodbus.client.sync import ModbusSerialClient
    except ImportError:
        print("  [X] pymodbus no instalado")
        sys.exit(1)

import time

sys.path.insert(0, os.environ.get('RPI_BRIDGE_DIR', '.'))
try:
    from modbus_helper import open_modbus_client
    client = open_modbus_client(port='/dev/ttyAMA0', timeout=1)
except ImportError:
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

print("  ┌─────────────────────────────────────────────────────────────┐")
print("  │  VALORES ACTUALES                                          │")
print("  ├─────────────────────────────────────────────────────────────┤")
print("  │  Fase   │  Reg 55 (estado_inicial)  │  Reg 56 (consigna)   │")
print("  ├─────────┼───────────────────────────┼──────────────────────┤")

problemas = []
errores_lectura = []
placas_ok = 0

for unit_id in [1, 2, 3]:
    fase = {1: "L1", 2: "L2", 3: "L3"}[unit_id]
    
    try:
        result = client.read_holding_registers(address=55, count=2, slave=unit_id)
        if result.isError():
            print(f"  │   {fase}    │  [X] Error leyendo        │  [X] Error leyendo   │")
            errores_lectura.append(fase)
            continue
        
        reg55 = result.registers[0]
        reg56 = result.registers[1]
        
        # Verificar si están corruptos
        r55_ok = reg55 in [0, 2]
        r56_ok = 1760 <= reg56 <= 2640
        
        r55_status = f"{reg55}" if r55_ok else f"{reg55} [!] CORRUPTO"
        r56_status = f"{reg56}" if r56_ok else f"{reg56} [!] CORRUPTO"
        
        print(f"  │   {fase}    │  {r55_status:<25} │  {r56_status:<20} │")
        
        if not r55_ok:
            problemas.append(f"{fase}: Reg55={reg55}")
        if not r56_ok:
            problemas.append(f"{fase}: Reg56={reg56}")
        
        if r55_ok and r56_ok:
            placas_ok += 1
            
    except Exception as e:
        print(f"  │   {fase}    │  [X] Error: {str(e)[:15]}   │  [X] Error           │")
        errores_lectura.append(fase)

client.close()

print("  └─────────────────────────────────────────────────────────────┘")
print("")

# Mostrar errores de lectura
if errores_lectura:
    print(f"  [X] ERROR DE LECTURA en: {', '.join(errores_lectura)}")
    print("      Verifica la conexión física con esas placas.")
    print("")

# Mostrar problemas de valores
if problemas:
    print("  [!] VALORES CORRUPTOS DETECTADOS:")
    for p in problemas:
        print(f"      - {p}")
    print("")
    print("  Valores válidos:")
    print("    - Reg 55: 0 (Bypass) o 2 (Regulación)")
    print("    - Reg 56: 1760-2640 (ej: 2200 para 220V)")

# Solo decir OK si las 3 placas responden Y están correctas
if placas_ok == 3 and not errores_lectura and not problemas:
    print("  [OK] Las 3 placas responden y tienen valores correctos.")
    print("       No hay nada que reparar.")
    sys.exit(2)
EOFLEER
    
    LEER_RESULT=$?
    
    # Si no hay problemas (exit 2), reiniciar y salir
    if [ $LEER_RESULT -eq 2 ]; then
        echo ""
        echo "  [~] Reiniciando Node-RED..."
        sudo systemctl start nodered
        docker start gesinne-rpi >/dev/null 2>&1 || true
        sleep 2
        echo "  [OK] Servicios reiniciados"
        return 0
    fi
    
    # Si hubo error de conexión (exit 1), salir
    if [ $LEER_RESULT -eq 1 ]; then
        echo ""
        echo "  [~] Reiniciando Node-RED..."
        sudo systemctl start nodered
        docker start gesinne-rpi >/dev/null 2>&1 || true
        return 1
    fi
    
    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ¿Qué valores quieres escribir?"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    read -p "  Registro 55 (estado_inicial) [0=Bypass, 2=Regulación]: " REG55_VALUE
    REG55_VALUE=${REG55_VALUE:-0}
    
    if [ "$REG55_VALUE" != "0" ] && [ "$REG55_VALUE" != "2" ]; then
        echo "  [X] Valor inválido. Debe ser 0 o 2"
        echo "  [~] Reiniciando Node-RED..."
        sudo systemctl start nodered
        docker start gesinne-rpi >/dev/null 2>&1 || true
        return 1
    fi
    
    read -p "  Registro 56 (tension_consigna) [1760-2640, ej: 2200]: " REG56_VALUE
    REG56_VALUE=${REG56_VALUE:-2200}
    
    if [ "$REG56_VALUE" -lt 1760 ] || [ "$REG56_VALUE" -gt 2640 ] 2>/dev/null; then
        echo "  [X] Valor inválido. Debe estar entre 1760 y 2640"
        echo "  [~] Reiniciando Node-RED..."
        sudo systemctl start nodered
        docker start gesinne-rpi >/dev/null 2>&1 || true
        return 1
    fi
    
    echo ""
    echo "  Valores a escribir:"
    echo "    - Registro 55 = $REG55_VALUE"
    echo "    - Registro 56 = $REG56_VALUE"
    echo ""
    read -p "  ¿Continuar con la escritura? [s/N]: " CONFIRM
    if [ "$CONFIRM" != "s" ] && [ "$CONFIRM" != "S" ]; then
        echo "  [X] Cancelado"
        echo "  [~] Reiniciando Node-RED..."
        sudo systemctl start nodered
        docker start gesinne-rpi >/dev/null 2>&1 || true
        return 0
    fi
    
    echo ""
    echo "  [M] Escribiendo valores en las placas..."
    echo ""
    
    python3 << EOFREPARAR
import sys, os
try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    try:
        from pymodbus.client.sync import ModbusSerialClient
    except ImportError:
        print("  [X] pymodbus no instalado")
        sys.exit(1)

import time

sys.path.insert(0, os.environ.get('RPI_BRIDGE_DIR', '.'))
try:
    from modbus_helper import open_modbus_client
    client = open_modbus_client(port='/dev/ttyAMA0', timeout=1)
except ImportError:
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

REG55_VALUE = $REG55_VALUE
REG56_VALUE = $REG56_VALUE

print("  [M] Reparando las 3 tarjetas...")
print("")

total_reparadas = 0
total_errores = 0

for unit_id in [1, 2, 3]:
    fase = {1: "L1", 2: "L2", 3: "L3"}[unit_id]
    print(f"  [{fase}] Procesando...", end=" ", flush=True)
    
    # Primero leer valores actuales
    try:
        result = client.read_holding_registers(address=55, count=2, slave=unit_id)
        if result.isError():
            print("[X] Error leyendo")
            total_errores += 1
            continue
        
        current_55 = result.registers[0]
        current_56 = result.registers[1]
        
        cambios = []
        
        # Verificar y reparar registro 55
        if current_55 not in [0, 2]:
            print(f"\n       Reg 55: {current_55} → {REG55_VALUE}", end="", flush=True)
            write_result = client.write_register(address=55, value=REG55_VALUE, slave=unit_id)
            if write_result.isError():
                print(" [X]", end="")
                total_errores += 1
            else:
                print(" [OK]", end="")
                cambios.append("R55")
            time.sleep(0.2)
        
        # Verificar y reparar registro 56
        if current_56 < 1760 or current_56 > 2640:
            print(f"\n       Reg 56: {current_56} → {REG56_VALUE}", end="", flush=True)
            write_result = client.write_register(address=56, value=REG56_VALUE, slave=unit_id)
            if write_result.isError():
                print(" [X]", end="")
                total_errores += 1
            else:
                print(" [OK]", end="")
                cambios.append("R56")
            time.sleep(0.2)
        
        if cambios:
            total_reparadas += 1
            print(f"\n       [OK] Reparada ({', '.join(cambios)})")
        else:
            print("[OK] Sin cambios necesarios")
            
    except Exception as e:
        print(f"[X] Error: {e}")
        total_errores += 1

client.close()

print("")
print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
if total_errores == 0:
    print(f"  [OK] REPARACIÓN COMPLETADA - {total_reparadas} placa(s) modificada(s)")
else:
    print(f"  [!] REPARACIÓN CON ERRORES - {total_errores} error(es)")
print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
EOFREPARAR
    
    echo ""
    echo "  [~] Reiniciando Node-RED..."
    sudo systemctl start nodered
    docker start gesinne-rpi >/dev/null 2>&1 || true
    sleep 3
    echo "  [OK] Servicios reiniciados"
}

# Actualizar el baudrate del nodo modbus-client de Node-RED (flows.json)
# Tras un cambio exitoso de velocidad en las placas, hay que cambiar también
# el baudrate que usa Node-RED para hablarles, sino dejaría de comunicar.
# Actualiza TODOS los flows.json relevantes del sistema:
#   - /home/<user>/.node-red/flows.json     (el que Node-RED usa en runtime)
#   - /opt/nodered-flows-cache/flows.json   (cache desde donde Actualizar Flow copia)
# Si solo se actualiza el primero, el siguiente "Actualizar Flow" deshace el cambio.
# Uso: actualizar_baudrate_nodered <NEW_BAUD>
actualizar_baudrate_nodered() {
    local NEW_BAUD="$1"
    echo ""
    echo "  [NR] Actualizando baudrate de Node-RED a $NEW_BAUD..."

    # Buscar todos los flows.json relevantes
    local FLOWS_FILES=()
    for f in /home/*/.node-red/flows.json /opt/nodered-flows-cache/flows.json; do
        if [ -f "$f" ]; then
            FLOWS_FILES+=("$f")
        fi
    done

    if [ ${#FLOWS_FILES[@]} -eq 0 ]; then
        echo "  [!] No se encontró ningún flows.json — actualízalo manualmente"
        return 1
    fi

    local ANY_FAIL=0
    for FLOWS_FILE in "${FLOWS_FILES[@]}"; do
        echo ""
        echo "  [NR] Procesando: $FLOWS_FILE"

        # Backup antes de tocar
        local BAK="${FLOWS_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
        cp "$FLOWS_FILE" "$BAK" 2>/dev/null || sudo cp "$FLOWS_FILE" "$BAK"
        echo "  [NR] Backup: $BAK"

        export NR_FLOWS_FILE="$FLOWS_FILE"
        export NR_NEW_BAUD="$NEW_BAUD"
        _actualizar_baudrate_nodered_un_archivo || ANY_FAIL=1
    done

    return $ANY_FAIL
}

_actualizar_baudrate_nodered_un_archivo() {
    python3 << 'EOFNR'
import json, os, sys
path = os.environ['NR_FLOWS_FILE']
new_baud_str = os.environ['NR_NEW_BAUD']
new_baud = int(new_baud_str)

# Timeouts mínimos seguros para cada baudrate (calibrados empíricamente).
# A menor baudrate, más tiempo por byte → necesitamos más holgura.
TIMEOUTS_POR_BAUD = {
    115200: {'clientTimeout': 1500, 'commandDelay': 50,  'reconnectTimeout': 2000},
    57600:  {'clientTimeout': 3000, 'commandDelay': 80,  'reconnectTimeout': 2000},
    38400:  {'clientTimeout': 4500, 'commandDelay': 100, 'reconnectTimeout': 2000},
}
TARGET = TIMEOUTS_POR_BAUD.get(new_baud, TIMEOUTS_POR_BAUD[115200])

try:
    with open(path) as f:
        flows = json.load(f)
except Exception as e:
    print(f"  [X] No se pudo leer {path}: {e}")
    sys.exit(1)

cambios = 0
for node in flows:
    if isinstance(node, dict) and node.get('type') == 'modbus-client':
        name = node.get('name') or node.get('id', '?')
        old_baud = node.get('serialBaudrate', '?')
        # Cambiar baudrate
        if str(old_baud) != str(new_baud):
            node['serialBaudrate'] = str(new_baud)
            cambios += 1
            print(f"    nodo '{name}': serialBaudrate {old_baud} → {new_baud}")
        # Ajustar timeouts SOLO si el valor actual es MENOR que el recomendado
        # (no bajamos timeouts que el usuario haya subido manualmente).
        for k, v_target in TARGET.items():
            v_actual = node.get(k)
            try:
                v_actual_int = int(v_actual) if v_actual is not None else 0
            except (ValueError, TypeError):
                v_actual_int = 0
            if v_actual_int < v_target:
                node[k] = v_target
                cambios += 1
                print(f"    nodo '{name}': {k} {v_actual} → {v_target}")

if cambios > 0:
    try:
        with open(path, 'w') as f:
            json.dump(flows, f, indent=4)
        print(f"  [OK] {cambios} ajuste(s) aplicado(s) a flows.json")
    except Exception as e:
        print(f"  [X] Error guardando flows.json: {e}")
        sys.exit(1)
else:
    print(f"  [=] No hizo falta cambiar nada en flows.json")
EOFNR
    return $?
}

# Cambiar velocidad Modbus de las 3 placas (registro 61)
# Mapeo firmware: 0 = 115200, 1 = 57600, 2 = 38400
cambiar_velocidad_modbus() {
    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Cambiar velocidad Modbus de las placas"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo "  [!]  Parando Node-RED temporalmente..."
    sudo systemctl stop nodered 2>/dev/null
    docker stop gesinne-rpi >/dev/null 2>&1 || true
    sleep 2
    echo "  [OK] Servicios parados"
    echo ""

    # --- Paso 1: leer y mostrar velocidad actual ---
    echo "  [M] Leyendo velocidad actual de las 3 placas..."
    CURRENT_VEL=$(python3 << 'EOFLEER'
import sys
try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    from pymodbus.client.sync import ModbusSerialClient

# IGUAL PATRÓN QUE LA OPCIÓN 4 (Leer placas): probar baudrates en bucle
# hasta encontrar el activo. NO depender del cache del helper.
BAUDRATES = [115200, 57600, 38400]
BAUD_MAP = {0: 115200, 1: 57600, 2: 38400}

client = None
connected_baud = None

for baudrate in BAUDRATES:
    sys.stderr.write(f"    Probando @ {baudrate} baud... ")
    sys.stderr.flush()
    c = None
    try:
        c = ModbusSerialClient(port='/dev/ttyAMA0', baudrate=baudrate,
                                bytesize=8, parity='N', stopbits=1, timeout=2)
        if not c.connect():
            sys.stderr.write("no conecta\n")
            continue
        # Probar TODOS los slaves (no solo el 1) — si el 1 está caído,
        # otro puede responder. Solo asumimos que esta es "la velocidad"
        # si las 3 responden (estado uniforme).
        respondieron = []
        for s in (1, 2, 3):
            try:
                r = c.read_holding_registers(address=61, count=1, slave=s)
                if r is not None and not r.isError():
                    respondieron.append(s)
            except Exception:
                pass
        if len(respondieron) == 3:
            sys.stderr.write("OK (3/3 responden)\n")
            client = c
            connected_baud = baudrate
            break
        elif respondieron:
            sys.stderr.write(f"PARCIAL (solo L{respondieron} responden — bus partido)\n")
            c.close()
            # Recordamos esta info para el mensaje final
            client = c  # marca para no marcar como "ninguna"
            connected_baud = baudrate
            # NO break: seguimos probando otros baudrates por si las otras placas están ahí
            client = None  # reset, no usar este cliente
        else:
            sys.stderr.write("sin respuesta\n")
            c.close()
    except Exception:
        sys.stderr.write("sin respuesta\n")
        if c:
            try: c.close()
            except: pass

if client is None:
    sys.stderr.write("  [X] Ninguna placa responde a 115200/57600/38400 — abortando\n")
    sys.stderr.write("      Revisa cable RS485, alimentación y terminación.\n")
    sys.exit(1)

sys.stderr.write(f"  [OK] Comunicación establecida a {connected_baud} baud\n")

# Ahora leer reg 61 de las 3 placas a esa velocidad
actual = {}
for slave in (1, 2, 3):
    try:
        rr = client.read_holding_registers(address=61, count=1, slave=slave)
        if rr is None or rr.isError():
            sys.stderr.write(f"    L{slave}: sin respuesta\n")
        else:
            v = rr.registers[0]
            b = BAUD_MAP.get(v, '?')
            actual[slave] = v
            sys.stderr.write(f"    L{slave}: reg61={v} ({b} baud)\n")
    except Exception as e:
        sys.stderr.write(f"    L{slave}: error - {e}\n")
client.close()

if len(actual) != 3:
    sys.stderr.write("  [X] No se pudieron leer las 3 placas a la misma velocidad.\n")
    sys.stderr.write("      Probable BUS PARTIDO (placas a velocidades distintas).\n")
    sys.stderr.write("      Usa la opción 8 (Rescatar bus Modbus partido) en su lugar.\n")
    sys.exit(2)
if len(set(actual.values())) != 1:
    sys.stderr.write("  [X] Las 3 placas tienen velocidades distintas — BUS PARTIDO.\n")
    sys.stderr.write("      Usa la opción 8 (Rescatar bus Modbus partido) para arreglarlo.\n")
    sys.exit(3)

# Único output a stdout: el valor actual (lo capturará bash)
print(list(actual.values())[0])
EOFLEER
)
    READ_EXIT=$?

    if [ $READ_EXIT -ne 0 ]; then
        echo ""
        echo "  [~] Reiniciando Node-RED..."
        sudo systemctl start nodered 2>/dev/null
        docker start gesinne-rpi >/dev/null 2>&1 || true
        return $READ_EXIT
    fi

    # Mostrar resumen y pedir nuevo valor
    case "$CURRENT_VEL" in
        0) CURRENT_BAUD="115200" ;;
        1) CURRENT_BAUD="57600"  ;;
        2) CURRENT_BAUD="38400"  ;;
        *) CURRENT_BAUD="?"      ;;
    esac
    echo ""
    echo "  [i] Velocidad actual: reg61=$CURRENT_VEL ($CURRENT_BAUD baud)"
    echo ""
    echo "  Valores posibles del registro 61:"
    echo "    0 = 115200 baud"
    echo "    1 =  57600 baud"
    echo "    2 =  38400 baud"
    echo ""
    read -p "  Nuevo valor [0/1/2] (ENTER para cancelar): " NEW_VEL
    if [ -z "$NEW_VEL" ]; then
        echo "  [~] Cancelado"
        echo ""
        echo "  [~] Reiniciando Node-RED..."
        sudo systemctl start nodered 2>/dev/null
        docker start gesinne-rpi >/dev/null 2>&1 || true
        return 0
    fi
    if [[ ! "$NEW_VEL" =~ ^[012]$ ]]; then
        echo "  [X] Valor no válido (debe ser 0, 1 o 2)"
        echo ""
        echo "  [~] Reiniciando Node-RED..."
        sudo systemctl start nodered 2>/dev/null
        docker start gesinne-rpi >/dev/null 2>&1 || true
        return 1
    fi
    if [ "$NEW_VEL" = "$CURRENT_VEL" ]; then
        echo "  [=] Las placas ya están en reg61=$NEW_VEL ($CURRENT_BAUD baud). Nada que hacer."
        echo ""
        echo "  [~] Reiniciando Node-RED..."
        sudo systemctl start nodered 2>/dev/null
        docker start gesinne-rpi >/dev/null 2>&1 || true
        return 0
    fi
    echo ""
    read -p "  ¿Confirmas escribir reg 61=$NEW_VEL en L1, L2 y L3? [s/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[sSyY]$ ]]; then
        echo "  [~] Cancelado"
        echo ""
        echo "  [~] Reiniciando Node-RED..."
        sudo systemctl start nodered 2>/dev/null
        docker start gesinne-rpi >/dev/null 2>&1 || true
        return 0
    fi

    # --- Paso 2: escribir y verificar ---
    echo ""
    export NEW_VEL CURRENT_VEL
    python3 << EOFVEL
import sys, os, time
try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    from pymodbus.client.sync import ModbusSerialClient

sys.path.insert(0, os.environ.get('RPI_BRIDGE_DIR', '.'))
try:
    from modbus_helper import open_modbus_client, redetect_and_open_modbus_client, _cache_path
    HAS_HELPER = True
except ImportError:
    HAS_HELPER = False

BAUD_MAP = {0: 115200, 1: 57600, 2: 38400}
NEW_VEL = int(os.environ['NEW_VEL'])
NEW_BAUD = BAUD_MAP[NEW_VEL]
CURRENT_VEL = int(os.environ.get('CURRENT_VEL', '-1'))
OLD_BAUD = BAUD_MAP.get(CURRENT_VEL, 115200)

# Abrir cliente DIRECTAMENTE a OLD_BAUD (sabemos a qué velocidad están las placas
# porque el paso anterior lo detectó probando los 3 baudrates). Sin cache helper.
client = ModbusSerialClient(port='/dev/ttyAMA0', baudrate=OLD_BAUD,
                             bytesize=8, parity='N', stopbits=1, timeout=2)

if not client.connect():
    print(f"  [X] No se pudo abrir puerto serie a {OLD_BAUD} baud para escritura")
    sys.exit(1)
MAX_RETRIES = 4
RETRY_SLEEP = 0.3


def verificar_3_placas(port, baud_target):
    """Abre cliente FORZANDO baud_target (NO autodetectar) y devuelve dict {slave: reg61_value}.

    IMPORTANTE: NO usar redetect_and_open_modbus_client aquí — autodetecta y
    podría conectarse a otra velocidad, dando reg61 correcto pero a velocidad
    equivocada, llevando a un diagnóstico falso. Forzamos siempre baud_target.
    """
    c = ModbusSerialClient(port=port, baudrate=baud_target,
                            bytesize=8, parity='N', stopbits=1, timeout=2)
    if not c.connect():
        return None  # no se pudo abrir
    out = {}
    for slave in (1, 2, 3):
        try:
            rr = c.read_holding_registers(address=61, count=1, slave=slave)
            if rr is not None and not rr.isError():
                out[slave] = rr.registers[0]
        except Exception:
            pass
    c.close()
    return out


# === PASO PREVIO: poner las 3 placas en BYPASS (reg 31 = 0) ===
# La placa rechaza la escritura de reg 61 si no está en bypass. Guardamos
# el estado previo de reg 31 para restaurarlo al final.
# Si la lectura inicial de reg 31 falla → ABORTAR (no podemos confirmar
# que esté en bypass, mejor no escribir reg 61 a ciegas).
print("")
print("  [BP] Leyendo estado actual (reg 31) y poniendo placas en BYPASS...")
estado31_previo = {}
lectura_fallida = []
for slave in (1, 2, 3):
    try:
        rr = client.read_holding_registers(address=31, count=1, slave=slave)
        if rr is not None and not rr.isError():
            estado31_previo[slave] = rr.registers[0]
            tag = "BYPASS" if rr.registers[0] == 0 else ("REGULACION" if rr.registers[0] == 2 else f"valor={rr.registers[0]}")
            print(f"    L{slave}: reg31 = {rr.registers[0]} ({tag})")
        else:
            lectura_fallida.append(slave)
            print(f"    L{slave}: NO RESPONDE a la lectura inicial")
    except Exception as e:
        lectura_fallida.append(slave)
        print(f"    L{slave}: error leyendo reg31 - {e}")

if lectura_fallida:
    print(f"  [X] No se pudo leer reg 31 en L{lectura_fallida} — ABORTANDO sin escribir reg 61")
    print(f"      Posibles causas: cable, terminación RS485, placa apagada, ruido.")
    print(f"      Sin lectura del bypass actual no es seguro tocar la velocidad.")
    client.close()
    sys.exit(5)

# Poner las que están en regulación a bypass y VERIFICAR el cambio
print("")
print("  [BP] Aplicando bypass a las placas en regulación y verificando...")
bypass_no_aplicado = []
for slave in (1, 2, 3):
    if estado31_previo.get(slave, 0) == 0:
        continue  # ya en bypass
    try:
        client.write_register(address=31, value=0, slave=slave)
        time.sleep(0.3)  # damos tiempo a que la placa entre en bypass
        # Verificar
        rr = client.read_holding_registers(address=31, count=1, slave=slave)
        if rr is not None and not rr.isError() and rr.registers[0] == 0:
            print(f"    L{slave}: BYPASS aplicado y verificado")
        else:
            cur = rr.registers[0] if (rr is not None and not rr.isError()) else "?"
            print(f"    L{slave}: bypass NO confirmado (reg31={cur})")
            bypass_no_aplicado.append(slave)
    except Exception as e:
        bypass_no_aplicado.append(slave)
        print(f"    L{slave}: error aplicando bypass - {e}")

if bypass_no_aplicado:
    print(f"  [X] No se pudo poner en bypass L{bypass_no_aplicado} — ABORTANDO")
    print(f"      Posibles causas: equipo con carga activa, firmware antiguo, regulación bloqueada.")
    print(f"      Pon el equipo en BYPASS manualmente desde Node-RED y reintenta.")
    client.close()
    sys.exit(6)

time.sleep(0.5)  # margen extra antes de escribir reg 61


def restaurar_bypass(client_para_restaurar, baud_str):
    """Restaura reg 31 a su valor previo en cada placa. Best-effort, no aborta."""
    print("")
    print(f"  [BP] Restaurando reg 31 al estado anterior (a {baud_str} baud)...")
    for slave in (1, 2, 3):
        prev = estado31_previo.get(slave)
        if prev is None or prev == 0:
            continue
        try:
            client_para_restaurar.write_register(address=31, value=prev, slave=slave)
            time.sleep(0.1)
            print(f"    L{slave}: reg31 restaurado a {prev}")
        except Exception as e:
            print(f"    L{slave}: error restaurando reg31 - {e}")


# === ESCRITURA REG 61 ===
# IMPORTANTE: la placa contesta el ACK del write reg 61 a la NUEVA velocidad
# (cambia inmediatamente al recibir el comando). El master sigue a la velocidad
# vieja → ve bytes basura interpretados como "Exception 134/0". IGNORAMOS la
# respuesta del write y juzgamos éxito por la verificación posterior leyendo
# reg 61 a la nueva velocidad.
#
# Secuencia mágica obligatoria antes del reg 61 (confirmado por test 2026-05-25):
#   write reg 30 = 43981  → "habilitar tarjeta"
#   write reg 40 = 47818  → "habilitar config"
#   write reg 61 = NEW_VEL
# Sin las 2 magic words la placa rechaza el write con Exception 134/0.

def write_silencioso(client, slave, address, value):
    """Hace write sin importar la respuesta. Silencia cualquier excepción."""
    try:
        client.write_register(address=address, value=value, slave=slave)
    except Exception:
        pass


def desbloquear_y_escribir_velocidad(client, slave, nueva_velocidad):
    """Secuencia completa para cambiar la velocidad de UNA placa.
    Las 3 escrituras se silencian — el éxito se juzga después leyendo reg 61
    a la nueva velocidad.
    """
    write_silencioso(client, slave, 30, 43981)   # habilitar tarjeta
    time.sleep(0.15)
    write_silencioso(client, slave, 40, 47818)   # habilitar config
    time.sleep(0.15)
    write_silencioso(client, slave, 61, nueva_velocidad)


# --- Intento 1: BROADCAST (slave=0) — 1 frame para las 3 placas ---
# Para broadcast también enviamos la secuencia completa (30, 40, 61).
print("")
print("  [B] Intento 1: BROADCAST (slave=0) — cambio sincronizado")
print("  [B] Secuencia: reg30=43981 -> reg40=47818 -> reg61={}".format(NEW_VEL))
desbloquear_y_escribir_velocidad(client, 0, NEW_VEL)
try: client.close()
except: pass

print("  [B] Esperando 2s a que las placas apliquen la nueva velocidad...")
time.sleep(2)

verif = verificar_3_placas('/dev/ttyAMA0', NEW_BAUD)
broadcast_ok = (verif is not None and len([s for s, v in verif.items() if v == NEW_VEL]) == 3)

if not broadcast_ok:
    # --- Intento 2: INDIVIDUAL a vieja velocidad ---
    # Algunas placas pueden no haber recibido el broadcast (ruido, terminación, etc.).
    # Reabrimos a la velocidad que aún tengan las que no cambiaron.
    print("  [~] Broadcast no aplicó completamente — pasando a INDIVIDUAL")
    OLD_BAUD = BAUD_MAP.get(CURRENT_VEL, 115200)
    print(f"  [I] Reabriendo a velocidad anterior {OLD_BAUD} baud para escribir individual...")
    client = ModbusSerialClient(port='/dev/ttyAMA0', baudrate=OLD_BAUD,
                                 bytesize=8, parity='N', stopbits=1, timeout=2)
    if client.connect():
        # Solo escribimos a las placas que NO se verificaron a NEW_BAUD
        ya_ok = {s for s, v in (verif or {}).items() if v == NEW_VEL}
        for slave in (1, 2, 3):
            if slave in ya_ok:
                print(f"    L{slave}: ya estaba OK por broadcast, salto")
                continue
            desbloquear_y_escribir_velocidad(client, slave, NEW_VEL)
            print(f"    L{slave}: secuencia 30->40->61 enviada (sin esperar ACK)")
            time.sleep(0.5)
        client.close()
    else:
        print(f"  [!] No se pudo reabrir a {OLD_BAUD} baud — algunas placas pueden estar ya a {NEW_BAUD}")

    print("  [V] Esperando 2s y verificando...")
    time.sleep(2)
    verif = verificar_3_placas('/dev/ttyAMA0', NEW_BAUD)


# --- Evaluación final por verificación ---
print("")
print(f"  [V] Verificación final con velocidad {NEW_BAUD} baud:")
if verif is None:
    print(f"    [X] No se pudo abrir puerto a {NEW_BAUD} baud. Estado del bus desconocido.")
    print(f"    INTERVENCION MANUAL REQUERIDA.")
    sys.exit(3)

ok_slaves = []
for slave in (1, 2, 3):
    v = verif.get(slave)
    if v is None:
        print(f"    L{slave}: sin respuesta a {NEW_BAUD} baud")
    elif v == NEW_VEL:
        print(f"    L{slave}: OK (reg61={v})")
        ok_slaves.append(slave)
    else:
        print(f"    L{slave}: reg61={v} (esperaba {NEW_VEL})")

# Borrar cache helper (la velocidad ha cambiado o intentamos cambiarla)
if HAS_HELPER:
    try:
        os.remove(_cache_path())
    except FileNotFoundError:
        pass

# Restaurar reg 31 (bypass) — a NEW_BAUD si todas OK, intentando ambas si parcial
print("")
if len(ok_slaves) == 3:
    print(f"  [BP] Restaurando reg 31 al estado anterior (a {NEW_BAUD} baud)...")
    # Forzar NEW_BAUD: aquí ya sabemos que las 3 placas están a NEW_BAUD
    # (verificado arriba). No autodetectar para no enmascarar problemas.
    client_r = ModbusSerialClient(port='/dev/ttyAMA0', baudrate=NEW_BAUD,
                                   bytesize=8, parity='N', stopbits=1, timeout=2)
    if client_r.connect():
        for slave in (1, 2, 3):
            prev = estado31_previo.get(slave)
            if prev is None or prev == 0:
                continue
            write_silencioso(client_r, slave, 31, prev)
            print(f"    L{slave}: reg31 restaurado a {prev}")
            time.sleep(0.1)
        client_r.close()

    print("")
    print(f"  [OK] Las 3 placas a {NEW_BAUD} baud y verificadas")
    sys.exit(0)

# Caso parcial o ninguna OK
print("")
if not ok_slaves:
    print(f"  [X] Ninguna placa cambió a {NEW_BAUD} baud.")
    # Diagnóstico extra: ¿siguen respondiendo a la velocidad VIEJA?
    OLD_BAUD = BAUD_MAP.get(CURRENT_VEL, 115200)
    if OLD_BAUD != NEW_BAUD:
        print(f"  [D] Diagnóstico: comprobando si siguen a {OLD_BAUD} baud...")
        v_old = verificar_3_placas('/dev/ttyAMA0', OLD_BAUD)
        if v_old:
            todas_viejas = all(v == CURRENT_VEL for v in v_old.values()) and len(v_old) == 3
            for slave in (1, 2, 3):
                vv = v_old.get(slave)
                if vv is None:
                    print(f"    L{slave}: sin respuesta también a {OLD_BAUD} baud")
                else:
                    print(f"    L{slave}: a {OLD_BAUD} baud reg61={vv}")
            if todas_viejas:
                print(f"  [D] Las 3 placas SIGUEN a {OLD_BAUD} baud — la placa RECHAZÓ el write reg 61.")
                print(f"      Causas más probables:")
                print(f"        - Equipo con carga activa (regulando consumo real)")
                print(f"        - Firmware no permite cambiar la velocidad por Modbus")
                print(f"        - reg 31 reporta bypass pero internamente sigue activo")
        else:
            print(f"  [D] No responden a {OLD_BAUD} baud tampoco — placas caídas o ruido en bus")
else:
    no_ok = [s for s in (1, 2, 3) if s not in ok_slaves]
    print(f"  [X] BUS PARTIDO: L{ok_slaves} a {NEW_BAUD} baud, L{no_ok} sin verificar.")

print(f"      Restaurando bypass en ambas velocidades por seguridad...")
# Intentar restaurar bypass en NEW_BAUD (para las que cambiaron)
for baud_intentar in (NEW_BAUD, BAUD_MAP.get(CURRENT_VEL, 115200)):
    try:
        cr = ModbusSerialClient(port='/dev/ttyAMA0', baudrate=baud_intentar,
                                 bytesize=8, parity='N', stopbits=1, timeout=2)
        if cr.connect():
            for slave in (1, 2, 3):
                prev = estado31_previo.get(slave)
                if prev is None or prev == 0:
                    continue
                write_silencioso(cr, slave, 31, prev)
                time.sleep(0.1)
            cr.close()
    except Exception:
        pass

print(f"      INTERVENCION MANUAL REQUERIDA.")
sys.exit(2)
EOFVEL

    PY_EXIT=$?

    # Si el cambio fue exitoso, actualizar también Node-RED para que use la nueva velocidad
    if [ $PY_EXIT -eq 0 ]; then
        case "$NEW_VEL" in
            0) NEW_BAUD_STR="115200" ;;
            1) NEW_BAUD_STR="57600"  ;;
            2) NEW_BAUD_STR="38400"  ;;
        esac
        actualizar_baudrate_nodered "$NEW_BAUD_STR"
    fi

    echo ""
    echo "  [~] Reiniciando Node-RED..."
    sudo systemctl start nodered 2>/dev/null
    docker start gesinne-rpi >/dev/null 2>&1 || true
    sleep 3
    echo "  [OK] Servicios reiniciados"
    return $PY_EXIT
}

# === RESCATAR BUS MODBUS PARTIDO ===
# Cuando las 3 placas han quedado a velocidades distintas (p.ej. tras un
# intento fallido de cambio), igualar las 3 a una velocidad común.
# Hablamos a CADA placa a SU velocidad actual y aplicamos la secuencia
# mágica (reg31=0 -> reg30=43981 -> reg40=47818 -> reg61=target).
rescatar_bus_modbus() {
    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Rescatar bus Modbus (placas a velocidades distintas)"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo "  [!]  Parando Node-RED temporalmente..."
    sudo systemctl stop nodered 2>/dev/null
    docker stop gesinne-rpi >/dev/null 2>&1 || true
    sleep 2
    echo "  [OK] Servicios parados"
    echo ""

    # Paso 1: detectar la velocidad de cada placa probando los 3 baudrates
    # Timeout corto (0.5s) y feedback en vivo. Total peor caso: 3*3*0.5s = 4.5s.
    echo "  [D] Detectando velocidad actual de cada placa..."
    DETECCION=$(python3 << 'EOFDET'
import sys
from pymodbus.client import ModbusSerialClient

BAUDS = [115200, 57600, 38400]
LABELS = {115200: "115200 baud (reg61=0)", 57600: "57600 baud (reg61=1)", 38400: "38400 baud (reg61=2)"}

estado = {}
for slave in (1, 2, 3):
    encontrado = None
    for baud in BAUDS:
        sys.stderr.write(f"    L{slave} @ {baud}... ")
        sys.stderr.flush()
        c = ModbusSerialClient(port='/dev/ttyAMA0', baudrate=baud,
                                bytesize=8, parity='N', stopbits=1, timeout=2)
        if not c.connect():
            sys.stderr.write("no conecta\n")
            continue
        try:
            r = c.read_holding_registers(address=61, count=1, slave=slave)
            if r is not None and not r.isError():
                encontrado = (baud, r.registers[0])
                c.close()
                sys.stderr.write(f"OK (reg61={r.registers[0]})\n")
                break
            else:
                sys.stderr.write("sin respuesta\n")
        except Exception:
            sys.stderr.write("sin respuesta\n")
        c.close()
    if encontrado:
        baud, val = encontrado
        estado[slave] = baud
    else:
        sys.stderr.write(f"    L{slave}: NO RESPONDE A NINGUNA VELOCIDAD\n")

# stdout: línea por slave con baudrate detectado (o "X" si no responde)
for slave in (1, 2, 3):
    print(estado.get(slave, 'X'))
EOFDET
)
    DET_EXIT=$?

    # Parsear: 3 líneas, baudrate de cada slave
    mapfile -t BAUD_PLACAS <<< "$DETECCION"
    L1_BAUD="${BAUD_PLACAS[0]}"
    L2_BAUD="${BAUD_PLACAS[1]}"
    L3_BAUD="${BAUD_PLACAS[2]}"

    # Si alguna no responde, abortar
    if [ "$L1_BAUD" = "X" ] || [ "$L2_BAUD" = "X" ] || [ "$L3_BAUD" = "X" ]; then
        echo ""
        echo "  [X] Alguna placa no responde a ningún baudrate."
        echo "      Revisa cable RS485, alimentación de placas, terminación."
        echo ""
        echo "  [~] Reiniciando Node-RED..."
        sudo systemctl start nodered 2>/dev/null
        docker start gesinne-rpi >/dev/null 2>&1 || true
        return 1
    fi

    # Mostrar el estado actual (partido o uniforme)
    echo ""
    if [ "$L1_BAUD" = "$L2_BAUD" ] && [ "$L2_BAUD" = "$L3_BAUD" ]; then
        echo "  [=] Las 3 placas están a $L1_BAUD baud (estado uniforme)"
    else
        echo "  [!] BUS PARTIDO detectado:"
        echo "      L1 a $L1_BAUD baud"
        echo "      L2 a $L2_BAUD baud"
        echo "      L3 a $L3_BAUD baud"
    fi
    echo ""
    echo "  Valores posibles para igualar las 3 placas:"
    echo "    0 = 115200 baud"
    echo "    1 =  57600 baud"
    echo "    2 =  38400 baud"
    echo ""
    read -p "  Velocidad objetivo [0/1/2] (ENTER para cancelar): " TARGET_VEL
    if [ -z "$TARGET_VEL" ]; then
        echo "  [~] Cancelado"
        sudo systemctl start nodered 2>/dev/null
        docker start gesinne-rpi >/dev/null 2>&1 || true
        return 0
    fi
    if [[ ! "$TARGET_VEL" =~ ^[012]$ ]]; then
        echo "  [X] Valor no válido"
        sudo systemctl start nodered 2>/dev/null
        docker start gesinne-rpi >/dev/null 2>&1 || true
        return 1
    fi

    case "$TARGET_VEL" in
        0) TARGET_BAUD="115200" ;;
        1) TARGET_BAUD="57600"  ;;
        2) TARGET_BAUD="38400"  ;;
    esac

    echo ""
    read -p "  ¿Confirmas igualar las 3 placas a $TARGET_BAUD baud (reg61=$TARGET_VEL)? [s/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[sSyY]$ ]]; then
        echo "  [~] Cancelado"
        sudo systemctl start nodered 2>/dev/null
        docker start gesinne-rpi >/dev/null 2>&1 || true
        return 0
    fi

    echo ""
    echo "  [W] Cambiando las placas que no están a $TARGET_BAUD baud..."

    export L1_BAUD L2_BAUD L3_BAUD TARGET_VEL TARGET_BAUD
    python3 << 'EOFRESC'
import os, sys, time
from pymodbus.client import ModbusSerialClient

TARGET_VEL = int(os.environ['TARGET_VEL'])
TARGET_BAUD = int(os.environ['TARGET_BAUD'])
BAUDS_PLACA = {
    1: int(os.environ['L1_BAUD']),
    2: int(os.environ['L2_BAUD']),
    3: int(os.environ['L3_BAUD']),
}

# Agrupar placas por la velocidad a la que están ahora
por_baud = {}
for slave, baud in BAUDS_PLACA.items():
    if baud == TARGET_BAUD:
        continue  # ya está, no toca
    por_baud.setdefault(baud, []).append(slave)

for baud, slaves in por_baud.items():
    print(f"  [W] Conectando a {baud} baud para hablar con L{slaves}...")
    c = ModbusSerialClient(port='/dev/ttyAMA0', baudrate=baud,
                            bytesize=8, parity='N', stopbits=1, timeout=2)
    if not c.connect():
        print(f"    [X] No se pudo abrir puerto a {baud} baud")
        continue

    for slave in slaves:
        print(f"    L{slave}: aplicando secuencia (bypass + magic words + reg61={TARGET_VEL})...")
        # bypass
        try: c.write_register(address=31, value=0, slave=slave)
        except Exception: pass
        time.sleep(0.3)
        # magic 30
        try: c.write_register(address=30, value=43981, slave=slave)
        except Exception: pass
        time.sleep(0.15)
        # magic 40
        try: c.write_register(address=40, value=47818, slave=slave)
        except Exception: pass
        time.sleep(0.15)
        # reg 61 (ACK vendrá a TARGET_BAUD, se ignora)
        try: c.write_register(address=61, value=TARGET_VEL, slave=slave)
        except Exception: pass
        time.sleep(0.5)

    c.close()

print()
print(f"  [V] Esperando 2s y verificando las 3 placas a {TARGET_BAUD} baud...")
time.sleep(2)

c = ModbusSerialClient(port='/dev/ttyAMA0', baudrate=TARGET_BAUD,
                       bytesize=8, parity='N', stopbits=1, timeout=2)
c.connect()
ok = 0
for slave in (1, 2, 3):
    try:
        r = c.read_holding_registers(address=61, count=1, slave=slave)
        if r is not None and not r.isError():
            v = r.registers[0]
            if v == TARGET_VEL:
                print(f"    L{slave}: OK (reg61={v})")
                ok += 1
            else:
                print(f"    L{slave}: reg61={v} (esperaba {TARGET_VEL})")
        else:
            print(f"    L{slave}: SIN RESPUESTA a {TARGET_BAUD} baud")
    except Exception as e:
        print(f"    L{slave}: error - {e}")
c.close()

# Borrar cache helper para que la app re-detecte
for path in ('/home/gesinne/config/baudrate_cache.json',
             '/home/pi/config/baudrate_cache.json',
             '/tmp/baudrate_cache.json'):
    try: os.remove(path)
    except FileNotFoundError: pass

print()
if ok == 3:
    print(f"  [OK] Bus rescatado — las 3 placas a {TARGET_BAUD} baud")
    sys.exit(0)
else:
    print(f"  [X] Solo {ok}/3 placas a {TARGET_BAUD} baud. INTERVENCION MANUAL.")
    sys.exit(2)
EOFRESC

    PY_EXIT=$?

    # Si el rescate fue exitoso, actualizar también Node-RED
    if [ $PY_EXIT -eq 0 ]; then
        actualizar_baudrate_nodered "$TARGET_BAUD"
    fi

    echo ""
    echo "  [~] Reiniciando Node-RED..."
    sudo systemctl start nodered 2>/dev/null
    docker start gesinne-rpi >/dev/null 2>&1 || true
    sleep 3
    echo "  [OK] Servicios reiniciados"
    return $PY_EXIT
}

# Si se llama con argumento "verificar", ejecutar directamente
if [ "$1" = "verificar" ]; then
    verificar_parametrizacion
    exit 0
fi

# Si se llama con argumento "rescatar-bus", igualar velocidades de las placas
if [ "$1" = "rescatar-bus" ] || [ "$1" = "rescatar_bus" ]; then
    rescatar_bus_modbus
    exit $?
fi

# Si se llama con argumento "reparar", ejecutar reparación
if [ "$1" = "reparar" ]; then
    reparar_placas
    exit 0
fi

# Si se llama con argumento "velocidad", cambiar velocidad Modbus
if [ "$1" = "velocidad" ]; then
    cambiar_velocidad_modbus
    exit $?
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
        # Opciones 1-5 deshabilitadas temporalmente — dejar solo cambio de velocidad
        # echo "  1) Descargar firmwares de GitHub"
        # echo "  2) Actualizar placa individual"
        # echo "  3) Actualizar L1, L2, L3 (guiado)"
        # echo "  4) Detectar micro conectado"
        # echo "  5) Enviar comando manual"
        echo "  6) Cambiar velocidad Modbus (reg 61)"
        echo "  7) Rescatar bus partido (igualar velocidades)"
        echo "  0) Salir"
        echo ""
        read -p "  Opcion [0/6/7]: " OPTION

        case "$OPTION" in
            # 1)
            #     download_firmwares
            #     ;;
            # 2)
            #     if [ ! -d "$FW_DIR/FW" ]; then
            #         echo "  [!] Primero descarga los firmwares (opcion 1)"
            #         continue
            #     fi
            #
            #     if ! list_versions; then
            #         continue
            #     fi
            #
            #     echo ""
            #     read -p "  Selecciona version: " VER_CHOICE
            #     SELECTED_VERSION="${VERSION_ARRAY[$VER_CHOICE]}"
            #
            #     if [ -z "$SELECTED_VERSION" ]; then
            #         echo "  [X] Version no valida"
            #         continue
            #     fi
            #
            #     echo ""
            #     read -p "  Nombre de la placa (ej: L1): " BOARD_NAME
            #     update_board "$BOARD_NAME" ""
            #     ;;
            # 3)
            #     if [ ! -d "$FW_DIR/FW" ]; then
            #         echo "  [!] Primero descarga los firmwares (opcion 1)"
            #         continue
            #     fi
            #
            #     if ! list_versions; then
            #         continue
            #     fi
            #
            #     echo ""
            #     read -p "  Selecciona version: " VER_CHOICE
            #     SELECTED_VERSION="${VERSION_ARRAY[$VER_CHOICE]}"
            #
            #     if [ -z "$SELECTED_VERSION" ]; then
            #         echo "  [X] Version no valida"
            #         continue
            #     fi
            #
            #     echo ""
            #     echo "  [i] Actualizacion guiada L1, L2, L3"
            #     echo "  [i] Version: $SELECTED_VERSION"
            #     echo ""
            #
            #     for board in L1 L2 L3; do
            #         read -p "  ¿Actualizar $board? [S/n]: " DO_BOARD
            #         if [ "$DO_BOARD" != "n" ] && [ "$DO_BOARD" != "N" ]; then
            #             update_board "$board" ""
            #         fi
            #     done
            #
            #     echo ""
            #     echo "  [OK] Proceso completado"
            #     ;;
            # 4)
            #     echo ""
            #     echo "  [!] Asegurate de que el cable esta conectado"
            #     read -p "  Pulsa ENTER para continuar..." dummy
            #     detect_micro
            #     ;;
            # 5)
            #     echo ""
            #     read -p "  Comando (sin ?): " CMD
            #     echo ""
            #     echo "  [~] Enviando ?$CMD..."
            #     response=$(send_command "?$CMD" 2)
            #     echo "  Respuesta:"
            #     echo "$response" | head -20
            #     ;;
            6)
                cambiar_velocidad_modbus
                ;;
            7)
                rescatar_bus_modbus
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
