#!/bin/bash
#
# Script oculto para Patricia - Opciones avanzadas
# Uso: bash oculto_patry.sh
#

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔐 Modo Patry - Opciones Ocultas"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  1) Optimizar rendimiento (zram + Modbus)"
echo "  2) Verificar validaciones del Flow"
echo "  3) Analizar bugs del Flow"
echo "  0) Salir"
echo ""
read -p "  Opción [0-3]: " PATRY_OPT

case $PATRY_OPT in
    1)
        echo ""
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Optimizar rendimiento (zram + Modbus)"
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        # 1. Instalar y configurar zram
        echo "  [1/2] Configurando zram (swap en RAM comprimida)..."
        if ! dpkg -s zram-tools &>/dev/null; then
            echo "  → Instalando zram-tools..."
            sudo apt-get update -qq
            sudo apt-get install -y -qq zram-tools
        fi
        
        echo "  → Configurando zram al 50% de RAM con LZ4..."
        echo -e "ALGO=lz4\nPERCENT=50" | sudo tee /etc/default/zramswap > /dev/null
        if systemctl list-unit-files | grep -q zramswap; then
            sudo systemctl restart zramswap
        else
            echo "  [!] Servicio zramswap no encontrado, intentando iniciar..."
            sudo systemctl start zramswap 2>/dev/null || true
        fi
        
        ZRAM_SIZE=$(free -h | grep Swap | awk '{print $2}')
        echo "  [OK] zram configurado: $ZRAM_SIZE de swap comprimido"
        echo ""
        
        # 2. Optimizar cliente Modbus en Node-RED
        echo "  [2/2] Optimizando cliente Modbus en Node-RED..."
        
        FLOWS_FILE=""
        for f in /home/*/.node-red/flows.json; do
            if [ -f "$f" ]; then
                FLOWS_FILE="$f"
                break
            fi
        done
        
        if [ -n "$FLOWS_FILE" ]; then
            # Backup
            cp "$FLOWS_FILE" "${FLOWS_FILE}.backup.$(date +%Y%m%d%H%M%S)"
            
            python3 -c "
import json
import sys
try:
    with open('$FLOWS_FILE', 'r') as f:
        flows = json.load(f)
except json.JSONDecodeError as e:
    print(f'  [X] Error: flows.json corrupto - {e}')
    sys.exit(1)
except Exception as e:
    print(f'  [X] Error leyendo flows.json - {e}')
    sys.exit(1)
changed = False
for node in flows:
    if node.get('type') == 'modbus-client':
        node['clientTimeout'] = 1000
        node['reconnectTimeout'] = 2000
        node['commandDelay'] = 300
        node['serialConnectionDelay'] = 500
        changed = True
        print('  [OK] Modbus client optimizado:')
        print('       • clientTimeout: 1000ms')
        print('       • reconnectTimeout: 2000ms')
        print('       • commandDelay: 300ms')
        print('       • serialConnectionDelay: 500ms')
if changed:
    with open('$FLOWS_FILE', 'w') as f:
        json.dump(flows, f, separators=(',', ':'))
else:
    print('  [!] No se encontró modbus-client en el flow')
"
            
            echo ""
            echo "  [~] Reiniciando Node-RED..."
            sudo systemctl restart nodered
            sleep 3
            echo "  [OK] Node-RED reiniciado"
        else
            echo "  [!] No se encontró flows.json"
        fi
        
        echo ""
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  [OK] Optimización completada:"
        echo "     • zram: swap comprimido en RAM (no desgasta SD)"
        echo "     • Modbus: timeouts optimizados (evita errores)"
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        ;;
    2)
        echo ""
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Verificar validaciones del Flow"
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        FLOWS_FILE=""
        for f in /home/*/.node-red/flows.json; do
            if [ -f "$f" ]; then
                FLOWS_FILE="$f"
                break
            fi
        done
        
        if [ -z "$FLOWS_FILE" ]; then
            echo "  [X] No se encontró flows.json"
        else
            echo "  [P] Analizando: $FLOWS_FILE"
            echo ""
            
            python3 -c "
import json
import sys

try:
    with open('$FLOWS_FILE', 'r') as f:
        flows = json.load(f)
except (json.JSONDecodeError, FileNotFoundError, PermissionError) as e:
    print(f'  [X] Error leyendo flows.json: {e}')
    sys.exit(1)

# === VALIDACIONES REQUERIDAS ===
validaciones = {
    'validar_estado_inicial': False,
    'validar_tipo_prueba': False,
    'estado_inicial_l1': False,
    'estado_inicial_l2': False,
    'estado_inicial_l3': False,
    'comprobar_cambios': False,
    'comparar_l1': False,
    'comparar_l2': False,
    'comparar_l3': False,
}

# === SUBFLOWS REQUERIDOS ===
subflows_requeridos = ['OK/Cancel helper', 'Delivery subflow', 'MQTT Processor']
subflows_encontrados = []

# === CONFIG ===
modbus_config = {}
mqtt_broker = None

for node in flows:
    name = node.get('name', '')
    node_type = node.get('type', '')
    func = node.get('func', '')
    
    # Subflows
    if node_type == 'subflow':
        subflows_encontrados.append(name)
    
    # Validación Estado Inicial (0, 1 o 2)
    if 'Validar Estado Inicial' in name or 'valor === 0 || valor === 1 || valor === 2' in func:
        validaciones['validar_estado_inicial'] = True
    
    # Validar Tipo de Prueba
    if 'Validar Tipo de Prueba' in name:
        validaciones['validar_tipo_prueba'] = True
    
    # Funciones EstadoInicialL1/L2/L3
    if name == 'EstadoInicialL1':
        validaciones['estado_inicial_l1'] = True
    if name == 'EstadoInicialL2':
        validaciones['estado_inicial_l2'] = True
    if name == 'EstadoInicialL3':
        validaciones['estado_inicial_l3'] = True
    
    # Comprobar cambios estado inicial
    if 'Comprobar cambios estado inicial' in name:
        validaciones['comprobar_cambios'] = True
    
    # Comparadores L1/L2/L3 <> Estado inicial
    if 'L1 <> Estado inicial' in name:
        validaciones['comparar_l1'] = True
    if 'L2 <> Estado inicial' in name:
        validaciones['comparar_l2'] = True
    if 'L3 <> Estado inicial' in name:
        validaciones['comparar_l3'] = True
    
    # Config Modbus
    if node_type == 'modbus-client':
        modbus_config = {
            'clientTimeout': node.get('clientTimeout', '?'),
            'reconnectTimeout': node.get('reconnectTimeout', '?'),
            'commandDelay': node.get('commandDelay', '?'),
            'serialConnectionDelay': node.get('serialConnectionDelay', '?')
        }
    
    # Config MQTT
    if node_type == 'mqtt-broker':
        mqtt_broker = node.get('broker', '?')

# === MOSTRAR RESULTADOS ===

print('  ┌─────────────────────────────────────────────┐')
print('  │          SUBFLOWS REQUERIDOS                │')
print('  └─────────────────────────────────────────────┘')
print('')
subflows_ok = 0
for sf in subflows_requeridos:
    if sf in subflows_encontrados:
        print(f'  [OK] {sf}')
        subflows_ok += 1
    else:
        print(f'  [X]  {sf} - NO ENCONTRADO')
print('')

print('  ┌─────────────────────────────────────────────┐')
print('  │          VALIDACIONES DE ESTADO             │')
print('  └─────────────────────────────────────────────┘')
print('')

if validaciones['validar_estado_inicial']:
    print('  [OK] Validar Estado Inicial (0, 1 o 2)')
else:
    print('  [X]  Validar Estado Inicial - NO ENCONTRADO')

if validaciones['validar_tipo_prueba']:
    print('  [OK] Validar Tipo de Prueba (0, 1 o 2)')
else:
    print('  [X]  Validar Tipo de Prueba - NO ENCONTRADO')

print('')
print('  Funciones por fase:')
for fase in ['l1', 'l2', 'l3']:
    key = f'estado_inicial_{fase}'
    if validaciones[key]:
        print(f'  [OK] EstadoInicial{fase.upper()}')
    else:
        print(f'  [X]  EstadoInicial{fase.upper()} - NO ENCONTRADO')

print('')
print('  Comparadores por fase:')
for fase in ['l1', 'l2', 'l3']:
    key = f'comparar_{fase}'
    if validaciones[key]:
        print(f'  [OK] {fase.upper()} <> Estado inicial')
    else:
        print(f'  [X]  {fase.upper()} <> Estado inicial - NO ENCONTRADO')

if validaciones['comprobar_cambios']:
    print('')
    print('  [OK] Comprobar cambios estado inicial')
else:
    print('')
    print('  [X]  Comprobar cambios estado inicial - NO ENCONTRADO')

# Modbus
print('')
print('  ┌─────────────────────────────────────────────┐')
print('  │          CONFIGURACIÓN MODBUS               │')
print('  └─────────────────────────────────────────────┘')
print('')
if modbus_config and modbus_config.get('clientTimeout') != '?':
    print(f\"  clientTimeout:         {modbus_config['clientTimeout']}ms\")
    print(f\"  reconnectTimeout:      {modbus_config['reconnectTimeout']}ms\")
    print(f\"  commandDelay:          {modbus_config['commandDelay']}ms\")
    print(f\"  serialConnectionDelay: {modbus_config['serialConnectionDelay']}ms\")
    try:
        timeout_val = modbus_config['clientTimeout']
        if isinstance(timeout_val, str):
            timeout_val = int(timeout_val.replace('ms', '').strip())
        else:
            timeout_val = int(timeout_val)
        if timeout_val >= 1000:
            print('')
            print('  [OK] Timeouts optimizados (>=1000ms)')
        else:
            print('')
            print('  [!]  Timeouts bajos - ejecutar opción 1 para optimizar')
    except:
        pass
else:
    print('  [X]  No se encontró configuración Modbus')

# MQTT
print('')
print('  ┌─────────────────────────────────────────────┐')
print('  │          CONFIGURACIÓN MQTT                 │')
print('  └─────────────────────────────────────────────┘')
print('')
mqtt_ok = False
if mqtt_broker:
    print(f'  Broker: {mqtt_broker}')
    if 'gesinne' in mqtt_broker or 'localhost' in mqtt_broker or '57.129.130.106' in mqtt_broker or '127.0.0.1' in mqtt_broker:
        print('  [OK] Broker configurado correctamente')
        mqtt_ok = True
    else:
        print('  [!]  Broker no es gesinne ni localhost')
else:
    print('  [X]  No se encontró configuración MQTT')

# === RESUMEN FINAL ===
print('')
print('  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
total_validaciones = sum(validaciones.values())
total_requeridas = len(validaciones)
print(f'  Validaciones: {total_validaciones}/{total_requeridas}')
print(f'  Subflows:     {subflows_ok}/{len(subflows_requeridos)}')
print(f'  MQTT:         {\"OK\" if mqtt_ok else \"REVISAR\"}')
print('  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')

if total_validaciones == total_requeridas and subflows_ok == len(subflows_requeridos) and mqtt_ok:
    print('  [OK] FLOW COMPLETO - Todas las validaciones OK')
    print('FLOW_OK')
else:
    print('  [!]  FLOW INCOMPLETO - Faltan elementos')
    if total_validaciones < total_requeridas:
        print(f'       → Faltan {total_requeridas - total_validaciones} validaciones')
    if subflows_ok < len(subflows_requeridos):
        print(f'       → Faltan {len(subflows_requeridos) - subflows_ok} subflows')
    print('FLOW_INCOMPLETO')
" | tee /tmp/flow_check_result.txt
            
            # Verificar si el flow está incompleto y ofrecer actualizar
            if grep -q "FLOW_INCOMPLETO" /tmp/flow_check_result.txt 2>/dev/null; then
                echo ""
                echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  ¿Quieres actualizar el flow con la versión completa?"
                echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "  [!] ADVERTENCIA: Esto reemplazará el flow actual"
                echo "      Se creará un backup antes de actualizar"
                echo ""
                read -p "  ¿Actualizar flow? [s/N]: " ACTUALIZAR_FLOW
                
                if [[ "$ACTUALIZAR_FLOW" =~ ^[Ss]$ ]]; then
                    echo ""
                    echo "  [~] Descargando flow de referencia..."
                    
                    # Backup del flow actual
                    cp "$FLOWS_FILE" "${FLOWS_FILE}.backup.$(date +%Y%m%d%H%M%S)"
                    echo "  [OK] Backup creado: ${FLOWS_FILE}.backup.$(date +%Y%m%d%H%M%S)"
                    
                    # Descargar flow de referencia
                    FLOW_URL="https://raw.githubusercontent.com/Gesinne/NODERED/main/20260102_dbrd2.json"
                    if curl -sSL "$FLOW_URL" -o /tmp/flow_nuevo.json 2>/dev/null; then
                        
                        # Preservar configuración actual (serie, MQTT, Modbus)
                        echo "  [~] Preservando configuración actual..."
                        python3 -c "
import json

# Leer flow actual
with open('$FLOWS_FILE', 'r') as f:
    flow_actual = json.load(f)

# Leer flow nuevo
with open('/tmp/flow_nuevo.json', 'r') as f:
    flow_nuevo = json.load(f)

# Extraer config del flow actual
mqtt_config = None
modbus_config = None
serie_config = None

for node in flow_actual:
    if node.get('type') == 'mqtt-broker':
        mqtt_config = node
    if node.get('type') == 'modbus-client':
        modbus_config = node

# Aplicar config al flow nuevo
for i, node in enumerate(flow_nuevo):
    if node.get('type') == 'mqtt-broker' and mqtt_config:
        # Preservar broker, user, password del actual
        flow_nuevo[i]['broker'] = mqtt_config.get('broker', flow_nuevo[i].get('broker'))
        flow_nuevo[i]['port'] = mqtt_config.get('port', flow_nuevo[i].get('port'))
        if mqtt_config.get('credentials'):
            flow_nuevo[i]['credentials'] = mqtt_config.get('credentials')
    if node.get('type') == 'modbus-client' and modbus_config:
        # Preservar puerto serial del actual
        flow_nuevo[i]['serialPort'] = modbus_config.get('serialPort', flow_nuevo[i].get('serialPort'))

# Guardar flow nuevo con config preservada
with open('$FLOWS_FILE', 'w') as f:
    json.dump(flow_nuevo, f, separators=(',', ':'))

print('  [OK] Flow actualizado con configuración preservada')
"
                        
                        echo ""
                        echo "  [~] Reiniciando Node-RED..."
                        sudo systemctl restart nodered
                        sleep 5
                        echo "  [OK] Node-RED reiniciado"
                        echo ""
                        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                        echo "  [OK] Flow actualizado correctamente"
                        echo "      Verifica el dashboard en /dashboard"
                        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    else
                        echo "  [X] Error descargando flow de referencia"
                    fi
                else
                    echo "  [X] Actualización cancelada"
                fi
            fi
            rm -f /tmp/flow_check_result.txt
        fi
        ;;
    3)
        echo ""
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Analizar bugs del Flow"
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        FLOWS_FILE=""
        for f in /home/*/.node-red/flows.json; do
            if [ -f "$f" ]; then
                FLOWS_FILE="$f"
                break
            fi
        done
        
        if [ -z "$FLOWS_FILE" ]; then
            echo "  [X] No se encontró flows.json"
        else
            echo "  [P] Analizando: $FLOWS_FILE"
            echo ""
            
            python3 << PYEOF
import json
import sys

try:
    with open('$FLOWS_FILE', 'r') as f:
        flows = json.load(f)
except Exception as e:
    print(f'  [X] Error leyendo flows.json: {e}')
    sys.exit(1)

bugs = []
warnings = []
fixes_disponibles = []

for node in flows:
    node_type = node.get('type', '')
    name = node.get('name', '')
    func = node.get('func', '')
    node_id = node.get('id', '')
    
    # === BUGS CRÍTICOS ===
    
    # 1. Lógica incorrecta en comparación de estado inicial
    if 'EstadoInicialL1 != estadoinicial' in func and '&& (EstadoInicialL3' in func:
        bugs.append({
            'tipo': 'CRÍTICO',
            'nodo': name,
            'id': node_id,
            'desc': 'Lógica incorrecta: usa && cuando debería ser ||',
            'fix': 'comprobar_cambios'
        })
        fixes_disponibles.append('comprobar_cambios')
    
    # 2. node.name puede ser undefined
    if node_type == 'function' and 'node.name' in func:
        bugs.append({
            'tipo': 'MEDIO',
            'nodo': name,
            'id': node_id,
            'desc': 'Usa node.name que puede ser undefined',
            'fix': None
        })
    
    # === ADVERTENCIAS ===
    
    # 3. parseInt/parseFloat sin verificar NaN
    if node_type == 'function' and ('parseInt(' in func or 'parseFloat(' in func):
        if 'isNaN' not in func:
            warnings.append(f"'{name}' usa parseInt/parseFloat sin verificar NaN")
    
    # 4. Acceso a array sin verificar longitud
    if node_type == 'function' and 'msg.payload.data[' in func:
        if '.length' not in func and 'undefined' not in func:
            warnings.append(f"'{name}' accede a array sin verificar longitud")
    
    # 5. MQTT con QoS 0
    if node_type == 'mqtt out':
        qos = node.get('qos', '0')
        if qos == '0' or qos == 0:
            warnings.append(f"MQTT out '{name or node_id[:8]}' con QoS 0 (sin garantía)")
    
    # 6. Delays muy largos
    if node_type == 'delay':
        try:
            timeout = int(node.get('timeout', 0))
            if timeout > 60:
                warnings.append(f"Delay '{name}' con timeout largo: {timeout}s")
        except:
            pass

# === MOSTRAR RESULTADOS ===

print('  ┌─────────────────────────────────────────────┐')
print('  │          BUGS CRÍTICOS                      │')
print('  └─────────────────────────────────────────────┘')
print('')

if bugs:
    for b in bugs:
        print(f"  [{b['tipo']}] {b['nodo']}")
        print(f"           {b['desc']}")
        if b['fix']:
            print(f"           → Corrección disponible")
        print('')
else:
    print('  [OK] No se encontraron bugs críticos')
    print('')

print('  ┌─────────────────────────────────────────────┐')
print('  │          ADVERTENCIAS                       │')
print('  └─────────────────────────────────────────────┘')
print('')

if warnings:
    for w in warnings[:10]:
        print(f'  [!] {w}')
    if len(warnings) > 10:
        print(f'  ... y {len(warnings) - 10} más')
    print('')
else:
    print('  [OK] No se encontraron advertencias')
    print('')

# === RESUMEN ===
print('  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
print(f'  Bugs críticos: {len(bugs)}')
print(f'  Advertencias:  {len(warnings)}')
print('  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')

# Guardar si hay fixes disponibles
if fixes_disponibles:
    with open('/tmp/bugs_fixes.txt', 'w') as f:
        f.write(','.join(fixes_disponibles))
    print('')
    print('  HAY_FIXES_DISPONIBLES')
PYEOF
            
            # Verificar si hay fixes disponibles
            if grep -q "HAY_FIXES_DISPONIBLES" /tmp/bugs_fixes.txt 2>/dev/null || [ -f /tmp/bugs_fixes.txt ]; then
                echo ""
                echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  ¿Quieres corregir los bugs automáticamente?"
                echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                read -p "  ¿Corregir bugs? [s/N]: " CORREGIR_BUGS
                
                if [[ "$CORREGIR_BUGS" =~ ^[Ss]$ ]]; then
                    echo ""
                    echo "  [~] Creando backup..."
                    cp "$FLOWS_FILE" "${FLOWS_FILE}.backup.$(date +%Y%m%d%H%M%S)"
                    
                    echo "  [~] Aplicando correcciones..."
                    
                    python3 << PYFIX
import json

with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)

cambios = 0

for node in flows:
    func = node.get('func', '')
    name = node.get('name', '')
    
    # Fix 1: Corregir lógica && por ||
    if 'Comprobar cambios estado inicial' in name or 'EstadoInicialL1 != estadoinicial' in func:
        if '&& (EstadoInicialL3' in func:
            # Corregir la lógica
            func_corregida = func.replace(
                '(EstadoInicialL2 != estadoinicial) && (EstadoInicialL3 != estadoinicial)',
                '(EstadoInicialL2 != estadoinicial) || (EstadoInicialL3 != estadoinicial)'
            )
            if func_corregida != func:
                node['func'] = func_corregida
                cambios += 1
                print(f"  [OK] Corregido: {name}")

if cambios > 0:
    with open('$FLOWS_FILE', 'w') as f:
        json.dump(flows, f, separators=(',', ':'))
    print(f"")
    print(f"  [OK] {cambios} corrección(es) aplicada(s)")
else:
    print("  [!] No se encontraron bugs para corregir")
PYFIX
                    
                    echo ""
                    echo "  [~] Reiniciando Node-RED..."
                    sudo systemctl restart nodered
                    sleep 3
                    echo "  [OK] Node-RED reiniciado"
                else
                    echo "  [X] Corrección cancelada"
                fi
                rm -f /tmp/bugs_fixes.txt
            fi
        fi
        ;;
    0|*)
        echo "  Saliendo..."
        ;;
esac

echo ""
read -p "  Presiona Enter para continuar..."
