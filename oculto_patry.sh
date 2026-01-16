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
echo "  0) Salir"
echo ""
read -p "  Opción [0-2]: " PATRY_OPT

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
        sudo systemctl restart zramswap
        
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
except:
    print('  [X] Error leyendo flows.json')
    sys.exit(1)

validaciones = {
    'estado_inicial': False,
    'dropdown_estado': False,
    'modbus_timeout': False,
    'mqtt_config': False
}

modbus_config = {}
mqtt_broker = None

for node in flows:
    # Verificar validación de estado inicial
    if node.get('id') == 'validacion_estado_inicial' or 'Validar Estado Inicial' in node.get('name', ''):
        validaciones['estado_inicial'] = True
    
    # Verificar dropdown de estado inicial
    if node.get('type') == 'ui-dropdown' and 'Estado Inicial' in node.get('name', ''):
        validaciones['dropdown_estado'] = True
    
    # Verificar config Modbus
    if node.get('type') == 'modbus-client':
        modbus_config = {
            'clientTimeout': node.get('clientTimeout', '?'),
            'reconnectTimeout': node.get('reconnectTimeout', '?'),
            'commandDelay': node.get('commandDelay', '?'),
            'serialConnectionDelay': node.get('serialConnectionDelay', '?')
        }
        try:
            if int(modbus_config['clientTimeout']) >= 1000:
                validaciones['modbus_timeout'] = True
        except:
            pass
    
    # Verificar config MQTT
    if node.get('type') == 'mqtt-broker':
        mqtt_broker = node.get('broker', '?')
        if 'gesinne' in mqtt_broker or 'localhost' in mqtt_broker:
            validaciones['mqtt_config'] = True

print('  ┌─────────────────────────────────────────────┐')
print('  │          VALIDACIONES DEL FLOW              │')
print('  └─────────────────────────────────────────────┘')
print('')

# Estado Inicial
if validaciones['estado_inicial']:
    print('  [OK] Validación Estado Inicial (0,1,2)')
else:
    print('  [X]  Validación Estado Inicial - NO ENCONTRADA')

if validaciones['dropdown_estado']:
    print('  [OK] Dropdown Estado Inicial')
else:
    print('  [X]  Dropdown Estado Inicial - NO ENCONTRADO')

# Modbus
print('')
print('  ┌─────────────────────────────────────────────┐')
print('  │          CONFIGURACIÓN MODBUS               │')
print('  └─────────────────────────────────────────────┘')
print('')
if modbus_config:
    print(f\"  clientTimeout:         {modbus_config['clientTimeout']}ms\")
    print(f\"  reconnectTimeout:      {modbus_config['reconnectTimeout']}ms\")
    print(f\"  commandDelay:          {modbus_config['commandDelay']}ms\")
    print(f\"  serialConnectionDelay: {modbus_config['serialConnectionDelay']}ms\")
    if validaciones['modbus_timeout']:
        print('')
        print('  [OK] Timeouts optimizados (>=1000ms)')
    else:
        print('')
        print('  [!]  Timeouts bajos - ejecutar opción 1 para optimizar')
else:
    print('  [X]  No se encontró configuración Modbus')

# MQTT
print('')
print('  ┌─────────────────────────────────────────────┐')
print('  │          CONFIGURACIÓN MQTT                 │')
print('  └─────────────────────────────────────────────┘')
print('')
if mqtt_broker:
    print(f'  Broker: {mqtt_broker}')
    if validaciones['mqtt_config']:
        print('  [OK] Broker configurado correctamente')
    else:
        print('  [!]  Broker no es gesinne ni localhost')
else:
    print('  [X]  No se encontró configuración MQTT')

# Resumen
print('')
print('  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
total_ok = sum(validaciones.values())
total = len(validaciones)
if total_ok == total:
    print(f'  [OK] TODAS las validaciones OK ({total_ok}/{total})')
else:
    print(f'  [!]  Validaciones: {total_ok}/{total} correctas')
    if not validaciones['estado_inicial']:
        print('       → Falta validación de Estado Inicial')
    if not validaciones['modbus_timeout']:
        print('       → Modbus necesita optimización (opción 1)')
"
        fi
        ;;
    0|*)
        echo "  Saliendo..."
        ;;
esac

echo ""
read -p "  Presiona Enter para continuar..."
