#!/bin/bash
#
# Script oculto para Patricia - Opciones avanzadas
# Uso: bash oculto_patry.sh
#

# Auto-actualizar desde Git
cd "$(dirname "$0")" 2>/dev/null || cd ~/rpi-azure-bridge 2>/dev/null
git pull --quiet 2>/dev/null

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔐 Modo Patry - Opciones Ocultas"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  1) Optimizar rendimiento (zram + Modbus)"
echo "  2) Analizar bugs del Flow"
echo "  3) Revisar el JSON"
echo "  4) Actualizar software"
echo "  5) Reparar placas desparametrizadas"
echo "  6) Activar persistencia de variables (anti-desparametrización)"
echo "  0) Salir"
echo ""
read -p "  Opción [0-6]: " PATRY_OPT

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
            echo "  [F] Analizando: $FLOWS_FILE"
            echo ""
            
            # Analizar y guardar bugs en archivo temporal
            python3 << PYEOF
import json
import sys
import re

try:
    with open('$FLOWS_FILE', 'r') as f:
        flows = json.load(f)
except Exception as e:
    print(f'  [X] Error leyendo flows.json: {e}')
    sys.exit(1)

bugs = []

for node in flows:
    node_type = node.get('type', '')
    name = node.get('name', '') or 'Sin nombre'
    func = node.get('func', '')
    node_id = node.get('id', '')
    
    # 1. node.name puede ser undefined
    if node_type == 'function' and 'node.name' in func:
        bugs.append({
            'num': len(bugs) + 1,
            'tipo': 'MEDIO',
            'nodo': name,
            'id': node_id,
            'desc': 'Usa node.name que puede ser undefined',
            'fix_type': 'node_name'
        })
    
    # 2. parseInt/parseFloat sin verificar NaN (ignorar si tiene try/catch, validación de match, o nombre genérico)
    if node_type == 'function' and ('parseInt(' in func or 'parseFloat(' in func):
        # Ignorar nodos con nombres genéricos (function 1, function 2, etc.)
        if name.startswith('function ') and name.split(' ')[-1].isdigit():
            pass  # Ignorar
        elif 'isNaN' not in func and 'try' not in func and 'catch' not in func and 'if (!match)' not in func and '|| 0' not in func:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'BAJO',
                'nodo': name,
                'id': node_id,
                'desc': 'Usa parseInt/parseFloat sin verificar NaN',
                'fix_type': 'parse_nan'
            })
    
    # 3. Acceso a array sin verificar longitud (ignorar nodos con nombres genéricos)
    if node_type == 'function' and 'msg.payload.data[' in func:
        # Ignorar nodos con nombres genéricos (function 1, function 2, etc.)
        if name.startswith('function ') and name.split(' ')[-1].isdigit():
            pass  # Ignorar
        elif '.length' not in func and 'undefined' not in func:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'MEDIO',
                'nodo': name,
                'id': node_id,
                'desc': 'Accede a array sin verificar longitud',
                'fix_type': 'array_length'
            })
    
    # 4. return; sin valor (debería ser return null;)
    if node_type == 'function' and 'return;' in func:
        if 'return msg' not in func and 'return null' not in func:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'BAJO',
                'nodo': name,
                'id': node_id,
                'desc': "Función con 'return;' sin valor (debería ser 'return null;')",
                'fix_type': 'return_null'
            })
    
    # 5. MQTT con QoS 0
    if node_type == 'mqtt out':
        qos = node.get('qos', '0')
        if qos == '0' or qos == 0:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'BAJO',
                'nodo': name,
                'id': node_id,
                'desc': 'MQTT con QoS 0 (sin garantía de entrega)',
                'fix_type': 'mqtt_qos'
            })
    
    # 5. Modbus timeouts bajos
    if node_type == 'modbus-client':
        timeout = node.get('clientTimeout', 0)
        if isinstance(timeout, int) and timeout < 1000:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'ALTO',
                'nodo': name or 'modbus-client',
                'id': node_id,
                'desc': f'Timeout Modbus muy bajo: {timeout}ms (recomendado: 1000ms)',
                'fix_type': 'modbus_timeout'
            })
    
    # 6. Escritura Modbus sin validación (EstadoInicial)
    if node_type == 'function' and name.startswith('EstadoInicial') and "global.get('estadoinicial')" in func:
        if 'estadoinicial !== 0 && estadoinicial !== 2' not in func and 'VALIDACIÓN' not in func:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'ALTO',
                'nodo': name,
                'id': node_id,
                'desc': 'Escritura Modbus sin validación de rango (debe ser 0 o 2)',
                'fix_type': 'estado_inicial_validacion'
            })
    
    # 7. Escritura Modbus sin validación (TensionConsigna)
    if node_type == 'function' and name.startswith('TensionConsigna') and "global.get('consigna')" in func:
        if 'consigna < 1760' not in func and 'VALIDACIÓN' not in func:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'ALTO',
                'nodo': name,
                'id': node_id,
                'desc': 'Escritura Modbus sin validación de rango (debe ser 1760-2640)',
                'fix_type': 'tension_consigna_validacion'
            })
    
    # 8. Crear variable global sin validación (consigna)
    if node_type == 'function' and name == 'Crear variable global' and 'global.set("consigna"' in func:
        if 'consigna < 1760' not in func and 'VALIDACIÓN' not in func:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'ALTO',
                'nodo': name,
                'id': node_id,
                'desc': 'Guarda consigna sin validar rango (debe ser 1760-2640)',
                'fix_type': 'crear_consigna_validacion'
            })
    
    # 9. Escritura Modbus sin validación (TensionInicial)
    if node_type == 'function' and name.startswith('TensionInicial') and "global.get('inicial')" in func:
        if 'inicial < 1760' not in func and 'VALIDACIÓN' not in func:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'ALTO',
                'nodo': name,
                'id': node_id,
                'desc': 'Escritura Modbus sin validación de rango (debe ser 1760-2640)',
                'fix_type': 'tension_inicial_validacion'
            })
    
    # 10. Crear variable global sin validación (inicial)
    if node_type == 'function' and name == 'Crear variable global' and 'global.set("inicial"' in func:
        if 'inicial < 1760' not in func and 'VALIDACIÓN' not in func:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'ALTO',
                'nodo': name,
                'id': node_id,
                'desc': 'Guarda inicial sin validar rango (debe ser 1760-2640)',
                'fix_type': 'crear_inicial_validacion'
            })
    
    # 11. Direcciones Modbus fuera de rango (registros válidos 0-65535)
    if node_type == 'modbus-read' or node_type == 'modbus-write':
        address = node.get('adr', node.get('address', 0))
        try:
            addr_val = int(address)
            if addr_val < 0 or addr_val > 65535:
                bugs.append({
                    'num': len(bugs) + 1,
                    'tipo': 'ALTO',
                    'nodo': name,
                    'id': node_id,
                    'desc': f'Dirección Modbus fuera de rango: {addr_val} (válido: 0-65535)',
                    'fix_type': 'modbus_address'
                })
        except:
            pass
    
    # 28. Escritura registro 31 (modo) sin protección anti-duplicados
    if node_type == 'function' and ("'address': 31" in func or '"address": 31' in func):
        if 'lastModo' not in func and 'Regulacion' in name or 'Bypass' in name:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'ALTO',
                'nodo': name,
                'id': node_id,
                'desc': 'Escritura reg 31 sin protección anti-duplicados',
                'fix_type': 'duplicados_reg31'
            })
    
    # 29. Escritura registro 32 (consigna) sin protección anti-duplicados
    if node_type == 'function' and name.startswith('TensionConsigna') and ("'address': 32" in func or '"address": 32' in func):
        if 'lastConsigna' not in func:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'ALTO',
                'nodo': name,
                'id': node_id,
                'desc': 'Escritura reg 32 sin protección anti-duplicados',
                'fix_type': 'duplicados_reg32'
            })
    
    # 30. Escritura registro 55 (estadoinicial) sin protección anti-duplicados
    if node_type == 'function' and name.startswith('EstadoInicial') and ("'address': 55" in func or '"address": 55' in func):
        if 'lastEstadoInicial' not in func:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'ALTO',
                'nodo': name,
                'id': node_id,
                'desc': 'Escritura reg 55 sin protección anti-duplicados',
                'fix_type': 'duplicados_reg55'
            })
    
    # 31. Escritura registro 56 (inicial) sin protección anti-duplicados
    if node_type == 'function' and name.startswith('TensionInicial') and ("'address': 56" in func or '"address": 56' in func):
        if 'lastInicial' not in func:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'ALTO',
                'nodo': name,
                'id': node_id,
                'desc': 'Escritura reg 56 sin protección anti-duplicados',
                'fix_type': 'duplicados_reg56'
            })
    
    # 32. Escritura Modbus con flow.get("fase") sin validación
    if node_type == 'function' and "'fc': 6" in func and 'flow.get("fase")' in func:
        if 'fase === undefined' not in func and 'fase < 1' not in func:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'MEDIO',
                'nodo': name,
                'id': node_id,
                'desc': 'Escritura Modbus con flow.get("fase") sin validación',
                'fix_type': 'validar_fase'
            })
    
    # 33. Flujo de configuración consigna roto (L1/L2/L3 <> consigna no conecta a TensionConsigna)
    if name in ['L1 <> consigna', 'L2 <> consigna', 'L3 <> consigna']:
        # Buscar el ID del nodo TensionConsigna correspondiente
        fase = name.split(' ')[0]  # L1, L2, L3
        tension_node_name = f'TensionConsigna{fase}'
        tension_id = None
        for n in flows:
            if n.get('name') == tension_node_name:
                tension_id = n.get('id')
                break
        
        # Verificar si el wire actual conecta al TensionConsigna
        wires = node.get('wires', [[]])
        if wires and wires[0]:
            current_target = wires[0][0] if wires[0] else None
            if current_target != tension_id:
                bugs.append({
                    'num': len(bugs) + 1,
                    'tipo': 'ALTO',
                    'nodo': name,
                    'id': node_id,
                    'desc': f'Flujo configuración roto: {name} no conecta a {tension_node_name}',
                    'fix_type': 'flujo_consigna',
                    'target_id': tension_id
                })
    
    # 12. Valores hardcodeados sospechosos en funciones (como 56112)
    # NOTA: Desactivado por generar muchos falsos positivos
    # Valores comunes válidos: 43981 (0xABCD), 47818, 51914 (0xCACA), 86400 (24h), 300000 (5min)
    
    # 13. División sin verificar divisor cero - SOLO casos claros
    # NOTA: Desactivado por generar muchos falsos positivos (/ en URLs, comentarios, etc.)
    
    # 14. Uso de eval() - peligroso
    if node_type == 'function' and 'eval(' in func:
        bugs.append({
            'num': len(bugs) + 1,
            'tipo': 'ALTO',
            'nodo': name,
            'id': node_id,
            'desc': 'Uso de eval() - riesgo de seguridad',
            'fix_type': 'eval_usage'
        })
    
    # 15. setTimeout/setInterval sin clearTimeout/clearInterval
    # NOTA: Desactivado - patrón común en Node-RED para animaciones/blink
    
    # 16. Modbus FC inválido
    if node_type == 'modbus-read' or node_type == 'modbus-write':
        fc = node.get('fc', '')
        valid_fc = ['1', '2', '3', '4', '5', '6', '15', '16', 1, 2, 3, 4, 5, 6, 15, 16]
        if fc and fc not in valid_fc:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'ALTO',
                'nodo': name,
                'id': node_id,
                'desc': f'Función Modbus inválida: FC={fc} (válidos: 1-6, 15, 16)',
                'fix_type': 'modbus_fc'
            })
    
    # 17. Inject con intervalo muy corto (< 1 segundo)
    # NOTA: Desactivado - 0.5s es común para lecturas Modbus rápidas
    
    # 18. Variables globales sin valor por defecto
    # NOTA: Desactivado - con persistencia activada (opción 6) las variables se guardan en disco
    # y no se pierden al reiniciar, por lo que este check ya no es necesario
    
    # 19. Comparación con == en lugar de === (puede causar bugs sutiles)
    if node_type == 'function' and ' == ' in func:
        # Ignorar si también usa === (probablemente sabe lo que hace)
        if ' === ' not in func and '!== ' not in func:
            # Contar ocurrencias
            count = func.count(' == ')
            if count > 0:
                bugs.append({
                    'num': len(bugs) + 1,
                    'tipo': 'BAJO',
                    'nodo': name,
                    'id': node_id,
                    'desc': f'Usa == en lugar de === ({count} ocurrencias) - puede causar bugs',
                    'fix_type': 'strict_equality'
                })
    
    # 20. msg.payload sin verificar null/undefined
    if node_type == 'function' and 'msg.payload.' in func:
        # Ignorar nodos de procesamiento Modbus (function 1-50, Store Data, etc.)
        nodos_modbus = ['function ' + str(i) for i in range(1, 51)] + ['Store Data L1', 'Store Data L2', 'Store Data L3']
        if name in nodos_modbus:
            pass  # Ignorar - siempre reciben datos de Modbus
        elif 'if (msg.payload' not in func and 'if (!msg.payload' not in func and 'msg.payload &&' not in func and '|| ' not in func and 'if (!match)' not in func:
            # Ignorar si tiene try/catch
            if 'try' not in func and 'catch' not in func:
                bugs.append({
                    'num': len(bugs) + 1,
                    'tipo': 'MEDIO',
                    'nodo': name,
                    'id': node_id,
                    'desc': 'Accede a msg.payload.* sin verificar si existe',
                    'fix_type': 'payload_check'
                })
    
    # 21. Nodos debug activos en producción
    if node_type == 'debug':
        active = node.get('active', True)
        if active == True or active == 'true':
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'BAJO',
                'nodo': name or 'debug',
                'id': node_id,
                'desc': 'Nodo debug activo (puede afectar rendimiento)',
                'fix_type': 'debug_active'
            })
    
    # 22. Inject sin topic definido
    # NOTA: Desactivado - los injects internos no necesitan topic, son disparadores locales
    
    # 23. Funciones muy largas (> 100 líneas) - difíciles de mantener
    if node_type == 'function':
        # Ignorar funciones conocidas que son largas por necesidad
        funciones_largas_ok = ['Modbus Queue', 'MQTT Processor', 'Delivery subflow']
        if name in funciones_largas_ok:
            pass  # Ignorar
        else:
            lines = func.count('\\n') + 1
            if lines > 100:
                bugs.append({
                    'num': len(bugs) + 1,
                    'tipo': 'BAJO',
                    'nodo': name,
                    'id': node_id,
                    'desc': f'Función muy larga ({lines} líneas) - difícil de mantener',
                    'fix_type': 'long_function'
                })
    
    # 24. Uso de var en lugar de let/const (ES6+)
    if node_type == 'function' and '\\nvar ' in func or func.startswith('var '):
        # Solo si no usa let/const en absoluto
        if 'let ' not in func and 'const ' not in func:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'BAJO',
                'nodo': name,
                'id': node_id,
                'desc': 'Usa var en lugar de let/const (estilo antiguo)',
                'fix_type': 'var_usage'
            })
    
    # 25. Modbus sin manejo de errores
    if node_type == 'modbus-flex-write' or node_type == 'modbus-flex-getter':
        # Verificar si tiene nodo catch conectado
        wires = node.get('wires', [])
        has_error_output = len(wires) > 1 and len(wires[1]) > 0
        if not has_error_output:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'MEDIO',
                'nodo': name or node_type,
                'id': node_id,
                'desc': 'Modbus flex sin salida de error conectada',
                'fix_type': 'modbus_error'
            })
    
    # 26. Guaranteed delivery con maxQueue muy bajo
    if node_type == 'guaranteed-delivery':
        max_queue = node.get('maxQueue', 0)
        if isinstance(max_queue, int) and max_queue < 100000:
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'MEDIO',
                'nodo': name or 'guaranteed-delivery',
                'id': node_id,
                'desc': f'maxQueue muy bajo: {max_queue} (recomendado: 500000+)',
                'fix_type': 'maxqueue_low'
            })
    
    # 27. Chronos sin timezone configurado
    if node_type == 'chronos-config':
        tz = node.get('timezone', '')
        if not tz or '/' not in str(tz):
            bugs.append({
                'num': len(bugs) + 1,
                'tipo': 'MEDIO',
                'nodo': name or 'chronos-config',
                'id': node_id,
                'desc': 'Chronos sin timezone configurado correctamente',
                'fix_type': 'chronos_tz'
            })

# Guardar bugs en archivo temporal
with open('/tmp/flow_bugs.json', 'w') as f:
    json.dump(bugs, f)

# Mostrar bugs
if not bugs:
    print('  [OK] No se encontraron bugs')
    print('')
else:
    print(f'  Se encontraron {len(bugs)} bugs:')
    print('')
    for b in bugs:
        tipo_color = {'ALTO': '🔴', 'MEDIO': '🟡', 'BAJO': '🟢'}.get(b['tipo'], '⚪')
        print(f"  {b['num']}) {tipo_color} [{b['tipo']}] {b['nodo']}")
        print(f"      {b['desc']}")
        print('')

print('BUGS_ENCONTRADOS=' + str(len(bugs)))
PYEOF
            
            # Leer cantidad de bugs
            BUGS_COUNT=$(python3 -c "import json; bugs=json.load(open('/tmp/flow_bugs.json')); print(len(bugs))" 2>/dev/null || echo "0")
            
            if [ "$BUGS_COUNT" -gt 0 ]; then
                echo ""
                echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  ¿Qué bug quieres corregir?"
                echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "  Introduce el número del bug (1-$BUGS_COUNT)"
                echo "  'a' para corregir TODOS"
                echo "  '0' para no corregir nada"
                echo ""
                read -p "  Opción: " BUG_OPT
                
                if [ "$BUG_OPT" = "0" ]; then
                    echo "  [X] Cancelado"
                elif [ "$BUG_OPT" = "a" ] || [ "$BUG_OPT" = "A" ]; then
                    echo ""
                    echo "  [~] Creando backup..."
                    cp "$FLOWS_FILE" "${FLOWS_FILE}.backup.$(date +%Y%m%d%H%M%S)"
                    
                    echo "  [~] Corrigiendo TODOS los bugs..."
                    
                    python3 << PYFIX
import json
import re

with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)

with open('/tmp/flow_bugs.json', 'r') as f:
    bugs = json.load(f)

cambios = 0

for bug in bugs:
    node_id = bug['id']
    fix_type = bug['fix_type']
    
    for node in flows:
        if node.get('id') == node_id:
            if fix_type == 'modbus_timeout':
                node['clientTimeout'] = 1000
                node['reconnectTimeout'] = 2000
                node['commandDelay'] = 300
                node['serialConnectionDelay'] = 500
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Timeouts Modbus optimizados")
            
            elif fix_type == 'mqtt_qos':
                node['qos'] = '1'
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - QoS cambiado a 1")
            
            elif fix_type == 'return_null':
                func = node.get('func', '')
                func = func.replace('return;', 'return null;')
                node['func'] = func
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - 'return;' cambiado a 'return null;'")
            
            elif fix_type == 'parse_nan':
                func = node.get('func', '')
                # Caso 1: parseFloat(config.potencia * 100)
                if 'parseFloat(config.potencia * 100)' in func:
                    func = func.replace(
                        "global.set('Pminima', parseFloat(config.potencia * 100));",
                        "var potenciaVal = parseFloat(config.potencia);\nif (!isNaN(potenciaVal)) {\n    global.set('Pminima', potenciaVal * 100);\n} else {\n    node.warn('Potencia no válida en config');\n}"
                    )
                    node['func'] = func
                    cambios += 1
                    print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación NaN para Pminima")
                # Caso 2: parseInt(msg.payload.match(...)[1]) - Configurar Máximo UI
                elif 'parseInt(msg.payload.match' in func and 'MemTotal' in func:
                    func = func.replace(
                        "const memTotalKB = parseInt(msg.payload.match(/MemTotal:\\s*(\\d+)/)[1]);",
                        "const match = msg.payload.match(/MemTotal:\\s*(\\d+)/);\nif (!match) {\n    node.warn('No se pudo leer MemTotal');\n    return null;\n}\nconst memTotalKB = parseInt(match[1]);"
                    )
                    node['func'] = func
                    cambios += 1
                    print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación para match null")
                # Caso 3: interrumpeFlujo - parseFloat de Pminima y sumaPotencias
                elif 'parseFloat(global.get("Pminima"))' in func and 'parseFloat(global.get("sumaPotencias"))' in func:
                    func = func.replace(
                        'var Pminima = parseFloat(global.get("Pminima"));',
                        'var Pminima = parseFloat(global.get("Pminima")) || 0;'
                    )
                    func = func.replace(
                        'var sumaPotencias = parseFloat(global.get("sumaPotencias"));',
                        'var sumaPotencias = parseFloat(global.get("sumaPotencias")) || 0;'
                    )
                    node['func'] = func
                    cambios += 1
                    print(f"  [OK] Corregido: {bug['nodo']} - Añadido valor por defecto 0 para Pminima y sumaPotencias")
                # Caso 4: Cálculo por matriz - parseFloat de sumaPotencias
                elif 'let sumaPotencias = parseFloat(global.get("sumaPotencias"));' in func:
                    func = func.replace(
                        'let sumaPotencias = parseFloat(global.get("sumaPotencias"));',
                        'let sumaPotencias = parseFloat(global.get("sumaPotencias")) || 0;'
                    )
                    node['func'] = func
                    cambios += 1
                    print(f"  [OK] Corregido: {bug['nodo']} - Añadido valor por defecto 0 para sumaPotencias")
            
            elif fix_type == 'array_length':
                func = node.get('func', '')
                # Caso: Procesar Alarmas L1/L2/L3
                if 'const alarmValue = msg.payload.data[2];' in func:
                    for phase in ['L1', 'L2', 'L3']:
                        if f"msg.phase = '{phase}';" in func:
                            func = func.replace(
                                "const alarmValue = msg.payload.data[2];",
                                f"if (!msg.payload.data || msg.payload.data.length < 3) {{\n    msg.payload = false;\n    msg.alarmValue = 0;\n    msg.phase = '{phase}';\n    return msg;\n}}\nconst alarmValue = msg.payload.data[2];"
                            )
                            node['func'] = func
                            cambios += 1
                            print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación de longitud de array")
                            break
            
            elif fix_type == 'estado_inicial_validacion':
                func = node.get('func', '')
                # Detectar unitid del nodo
                unitid = '1'
                if 'L2' in bug['nodo']:
                    unitid = '2'
                elif 'L3' in bug['nodo']:
                    unitid = '3'
                
                nuevo_codigo = f"""// VALIDACIÓN CRÍTICA: Verificar que estadoinicial sea 0 o 2
var estadoinicial = global.get('estadoinicial');
if (estadoinicial !== 0 && estadoinicial !== 2) {{
    node.error("ERROR CRÍTICO: estadoinicial fuera de rango (0 o 2). Valor: " + estadoinicial + ". Escritura bloqueada.");
    return null;
}}

msg.payload = {{
    value: estadoinicial,
    'fc': 6,
    'unitid': {unitid},
    'address': 55,
    'quantity': 1
}}
msg.topic = "{bug['nodo']}"
return msg;"""
                node['func'] = nuevo_codigo
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación de rango (0 o 2)")
            
            elif fix_type == 'tension_consigna_validacion':
                func = node.get('func', '')
                # Detectar unitid del nodo
                unitid = '1'
                if 'L2' in bug['nodo']:
                    unitid = '2'
                elif 'L3' in bug['nodo']:
                    unitid = '3'
                
                nuevo_codigo = f"""// VALIDACIÓN CRÍTICA: Verificar que consigna esté entre 1760-2640
var consigna = global.get('consigna');
if (consigna < 1760 || consigna > 2640) {{
    node.error("ERROR CRÍTICO: consigna fuera de rango (1760-2640). Valor: " + consigna + ". Escritura bloqueada.");
    return null;
}}

msg.payload = {{
    value: consigna,
    'fc': 6,
    'unitid': {unitid},
    'address': 32,
    'quantity': 1
}}
msg.topic = "TensionConsigna L{unitid}"
return msg;"""
                node['func'] = nuevo_codigo
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación de rango (1760-2640)")
            
            elif fix_type == 'crear_consigna_validacion':
                nuevo_codigo = """// VALIDACIÓN CRÍTICA: Verificar que consigna esté entre 1760-2640
var consigna = msg.payload * 10;
if (consigna < 1760 || consigna > 2640) {
    node.error("ERROR CRÍTICO: consigna fuera de rango (1760-2640). Valor: " + consigna + ". No se guarda.");
    return null;
}
global.set("consigna", consigna);
return msg;"""
                node['func'] = nuevo_codigo
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación de rango (1760-2640)")
            
            elif fix_type == 'tension_inicial_validacion':
                func = node.get('func', '')
                # Detectar unitid del nodo
                unitid = '1'
                if 'L2' in bug['nodo']:
                    unitid = '2'
                elif 'L3' in bug['nodo']:
                    unitid = '3'
                
                nuevo_codigo = f"""// VALIDACIÓN CRÍTICA: Verificar que inicial esté entre 1760-2640
var inicial = global.get('inicial');
if (inicial < 1760 || inicial > 2640) {{
    node.error("ERROR CRÍTICO: inicial fuera de rango (1760-2640). Valor: " + inicial + ". Escritura bloqueada.");
    return null;
}}

msg.payload = {{
    value: inicial,
    'fc': 6,
    'unitid': {unitid},
    'address': 56,
    'quantity': 1
}}
msg.topic = "TensionInicial L{unitid}"
return msg;"""
                node['func'] = nuevo_codigo
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación de rango (1760-2640)")
            
            elif fix_type == 'crear_inicial_validacion':
                nuevo_codigo = """// VALIDACIÓN CRÍTICA: Verificar que inicial esté entre 1760-2640
var inicial = msg.payload * 10;
if (inicial < 1760 || inicial > 2640) {
    node.error("ERROR CRÍTICO: inicial fuera de rango (1760-2640). Valor: " + inicial + ". No se guarda.");
    return null;
}
global.set("inicial", inicial);
return msg;"""
                node['func'] = nuevo_codigo
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación de rango (1760-2640)")
            
            elif fix_type == 'var_usage':
                func = node.get('func', '')
                func = re.sub(r'\bvar\s+', 'let ', func)
                node['func'] = func
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - 'var' cambiado a 'let'")
            
            elif fix_type == 'debug_active':
                node['active'] = False
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Debug desactivado")
            
            elif fix_type == 'maxqueue_low':
                node['maxQueue'] = 500000
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - maxQueue aumentado a 500000")
            
            elif fix_type == 'chronos_tz':
                node['timezone'] = 'Europe/Madrid'
                node['timezoneType'] = 'str'
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Timezone configurado a Europe/Madrid")
            
            elif fix_type == 'strict_equality':
                func = node.get('func', '')
                func = func.replace(' == ', ' === ')
                func = func.replace(' != ', ' !== ')
                node['func'] = func
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - '==' cambiado a '==='")
            
            elif fix_type == 'duplicados_reg31':
                func = node.get('func', '')
                fase = '1'
                if 'L2' in bug['nodo']:
                    fase = '2'
                elif 'L3' in bug['nodo']:
                    fase = '3'
                valor = '2' if 'Regulacion' in bug['nodo'] else '0'
                var_name = f'lastModoL{fase}'
                proteccion = f'let val = {valor}; if (val !== 0 && val !== 2) {{ node.error("Valor modo inválido: " + val); return null; }} let last = flow.get("{var_name}", "file"); if (last !== undefined && last === val) {{ return null; }} flow.set("{var_name}", val, "file");\\n'
                func = proteccion + func
                node['func'] = func
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Añadida protección anti-duplicados reg 31")
            
            elif fix_type == 'duplicados_reg32':
                func = node.get('func', '')
                fase = '1'
                if 'L2' in bug['nodo']:
                    fase = '2'
                elif 'L3' in bug['nodo']:
                    fase = '3'
                var_name = f'lastConsignaL{fase}'
                proteccion = f"let consigna = global.get('consigna'); if (consigna === undefined || consigna === null || isNaN(consigna) || consigna < 1760 || consigna > 2640) {{ node.error('Consigna inválida: ' + consigna); return null; }} let last = flow.get('{var_name}', 'file'); if (last !== undefined && last === consigna) {{ return null; }} flow.set('{var_name}', consigna, 'file');\\n"
                func = proteccion + func
                node['func'] = func
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Añadida protección anti-duplicados reg 32")
            
            elif fix_type == 'duplicados_reg55':
                func = node.get('func', '')
                fase = '1'
                if 'L2' in bug['nodo']:
                    fase = '2'
                elif 'L3' in bug['nodo']:
                    fase = '3'
                var_name = f'lastEstadoInicialL{fase}'
                proteccion = f"let estadoinicial = global.get('estadoinicial'); if (estadoinicial !== 0 && estadoinicial !== 2) {{ node.error('EstadoInicial inválido: ' + estadoinicial); return null; }} let last = flow.get('{var_name}', 'file'); if (last !== undefined && last === estadoinicial) {{ return null; }} flow.set('{var_name}', estadoinicial, 'file');\\n"
                func = proteccion + func
                node['func'] = func
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Añadida protección anti-duplicados reg 55")
            
            elif fix_type == 'duplicados_reg56':
                func = node.get('func', '')
                fase = '1'
                if 'L2' in bug['nodo']:
                    fase = '2'
                elif 'L3' in bug['nodo']:
                    fase = '3'
                var_name = f'lastInicialL{fase}'
                proteccion = f"let inicial = global.get('inicial'); if (inicial === undefined || inicial === null || isNaN(inicial) || inicial < 1760 || inicial > 2640) {{ node.error('Inicial inválido: ' + inicial); return null; }} let last = flow.get('{var_name}', 'file'); if (last !== undefined && last === inicial) {{ return null; }} flow.set('{var_name}', inicial, 'file');\\n"
                func = proteccion + func
                node['func'] = func
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Añadida protección anti-duplicados reg 56")
            
            elif fix_type == 'validar_fase':
                func = node.get('func', '')
                validacion = 'let fase = flow.get("fase"); if (fase === undefined || fase < 1 || fase > 3) { node.error("Fase inválida: " + fase); return null; }\\n'
                func = validacion + func
                node['func'] = func
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación de fase")
            
            elif fix_type == 'flujo_consigna':
                target_id = bug.get('target_id')
                if target_id:
                    node['wires'] = [[target_id]]
                    cambios += 1
                    print(f"  [OK] Corregido: {bug['nodo']} - Reconectado al nodo TensionConsigna")
            
            break

if cambios > 0:
    with open('$FLOWS_FILE', 'w') as f:
        json.dump(flows, f, separators=(',', ':'))
    print(f"")
    print(f"  [OK] {cambios} corrección(es) aplicada(s)")
else:
    print("  [!] No hay correcciones automáticas disponibles para estos bugs")
PYFIX
                    
                    if [ $? -eq 0 ]; then
                        echo ""
                        read -p "  ¿Reiniciar Node-RED para aplicar cambios? [s/N]: " REINICIAR
                        if [[ "$REINICIAR" =~ ^[Ss]$ ]]; then
                            echo "  [~] Reiniciando Node-RED..."
                            sudo systemctl restart nodered
                            sleep 3
                            echo "  [OK] Node-RED reiniciado"
                        fi
                    fi
                    
                elif [ "$BUG_OPT" -ge 1 ] 2>/dev/null && [ "$BUG_OPT" -le "$BUGS_COUNT" ] 2>/dev/null; then
                    echo ""
                    echo "  [~] Creando backup..."
                    cp "$FLOWS_FILE" "${FLOWS_FILE}.backup.$(date +%Y%m%d%H%M%S)"
                    
                    echo "  [~] Corrigiendo bug #$BUG_OPT..."
                    
                    python3 << PYFIX
import json
import re

with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)

with open('/tmp/flow_bugs.json', 'r') as f:
    bugs = json.load(f)

bug_num = $BUG_OPT
bug = bugs[bug_num - 1]
node_id = bug['id']
fix_type = bug['fix_type']

cambios = 0

for node in flows:
    if node.get('id') == node_id:
        if fix_type == 'modbus_timeout':
            node['clientTimeout'] = 1000
            node['reconnectTimeout'] = 2000
            node['commandDelay'] = 300
            node['serialConnectionDelay'] = 500
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - Timeouts Modbus optimizados")
        
        elif fix_type == 'mqtt_qos':
            node['qos'] = '1'
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - QoS cambiado a 1")
        
        elif fix_type == 'return_null':
            func = node.get('func', '')
            func = func.replace('return;', 'return null;')
            node['func'] = func
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - 'return;' cambiado a 'return null;'")
        
        elif fix_type == 'parse_nan':
            func = node.get('func', '')
            # Caso 1: parseFloat(config.potencia * 100)
            if 'parseFloat(config.potencia * 100)' in func:
                func = func.replace(
                    "global.set('Pminima', parseFloat(config.potencia * 100));",
                    "var potenciaVal = parseFloat(config.potencia);\nif (!isNaN(potenciaVal)) {\n    global.set('Pminima', potenciaVal * 100);\n} else {\n    node.warn('Potencia no válida en config');\n}"
                )
                node['func'] = func
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación NaN para Pminima")
            # Caso 2: parseInt(msg.payload.match(...)[1]) - Configurar Máximo UI
            elif 'parseInt(msg.payload.match' in func and 'MemTotal' in func:
                func = func.replace(
                    "const memTotalKB = parseInt(msg.payload.match(/MemTotal:\\s*(\\d+)/)[1]);",
                    "const match = msg.payload.match(/MemTotal:\\s*(\\d+)/);\nif (!match) {\n    node.warn('No se pudo leer MemTotal');\n    return null;\n}\nconst memTotalKB = parseInt(match[1]);"
                )
                node['func'] = func
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación para match null")
            # Caso 3: interrumpeFlujo - parseFloat de Pminima y sumaPotencias
            elif 'parseFloat(global.get("Pminima"))' in func and 'parseFloat(global.get("sumaPotencias"))' in func:
                func = func.replace(
                    'var Pminima = parseFloat(global.get("Pminima"));',
                    'var Pminima = parseFloat(global.get("Pminima")) || 0;'
                )
                func = func.replace(
                    'var sumaPotencias = parseFloat(global.get("sumaPotencias"));',
                    'var sumaPotencias = parseFloat(global.get("sumaPotencias")) || 0;'
                )
                node['func'] = func
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Añadido valor por defecto 0 para Pminima y sumaPotencias")
            # Caso 4: Cálculo por matriz - parseFloat de sumaPotencias
            elif 'let sumaPotencias = parseFloat(global.get("sumaPotencias"));' in func:
                func = func.replace(
                    'let sumaPotencias = parseFloat(global.get("sumaPotencias"));',
                    'let sumaPotencias = parseFloat(global.get("sumaPotencias")) || 0;'
                )
                node['func'] = func
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Añadido valor por defecto 0 para sumaPotencias")
        
        elif fix_type == 'array_length':
            func = node.get('func', '')
            # Caso: Procesar Alarmas L1/L2/L3
            if 'const alarmValue = msg.payload.data[2];' in func:
                for phase in ['L1', 'L2', 'L3']:
                    if f"msg.phase = '{phase}';" in func:
                        func = func.replace(
                            "const alarmValue = msg.payload.data[2];",
                            f"if (!msg.payload.data || msg.payload.data.length < 3) {{\n    msg.payload = false;\n    msg.alarmValue = 0;\n    msg.phase = '{phase}';\n    return msg;\n}}\nconst alarmValue = msg.payload.data[2];"
                        )
                        node['func'] = func
                        cambios += 1
                        print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación de longitud de array")
                        break
        
        elif fix_type == 'estado_inicial_validacion':
            func = node.get('func', '')
            # Detectar unitid del nodo
            unitid = '1'
            if 'L2' in bug['nodo']:
                unitid = '2'
            elif 'L3' in bug['nodo']:
                unitid = '3'
            
            nuevo_codigo = f"""// VALIDACIÓN CRÍTICA: Verificar que estadoinicial sea 0 o 2
var estadoinicial = global.get('estadoinicial');
if (estadoinicial !== 0 && estadoinicial !== 2) {{
    node.error("ERROR CRÍTICO: estadoinicial fuera de rango (0 o 2). Valor: " + estadoinicial + ". Escritura bloqueada.");
    return null;
}}

msg.payload = {{
    value: estadoinicial,
    'fc': 6,
    'unitid': {unitid},
    'address': 55,
    'quantity': 1
}}
msg.topic = "{bug['nodo']}"
return msg;"""
            node['func'] = nuevo_codigo
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación de rango (0 o 2)")
        
        elif fix_type == 'tension_consigna_validacion':
            func = node.get('func', '')
            # Detectar unitid del nodo
            unitid = '1'
            if 'L2' in bug['nodo']:
                unitid = '2'
            elif 'L3' in bug['nodo']:
                unitid = '3'
            
            nuevo_codigo = f"""// VALIDACIÓN CRÍTICA: Verificar que consigna esté entre 1760-2640
var consigna = global.get('consigna');
if (consigna < 1760 || consigna > 2640) {{
    node.error("ERROR CRÍTICO: consigna fuera de rango (1760-2640). Valor: " + consigna + ". Escritura bloqueada.");
    return null;
}}

msg.payload = {{
    value: consigna,
    'fc': 6,
    'unitid': {unitid},
    'address': 32,
    'quantity': 1
}}
msg.topic = "TensionConsigna L{unitid}"
return msg;"""
            node['func'] = nuevo_codigo
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación de rango (1760-2640)")
        
        elif fix_type == 'crear_consigna_validacion':
            nuevo_codigo = """// VALIDACIÓN CRÍTICA: Verificar que consigna esté entre 1760-2640
var consigna = msg.payload * 10;
if (consigna < 1760 || consigna > 2640) {
    node.error("ERROR CRÍTICO: consigna fuera de rango (1760-2640). Valor: " + consigna + ". No se guarda.");
    return null;
}
global.set("consigna", consigna);
return msg;"""
            node['func'] = nuevo_codigo
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación de rango (1760-2640)")
        
        elif fix_type == 'tension_inicial_validacion':
            func = node.get('func', '')
            # Detectar unitid del nodo
            unitid = '1'
            if 'L2' in bug['nodo']:
                unitid = '2'
            elif 'L3' in bug['nodo']:
                unitid = '3'
            
            nuevo_codigo = f"""// VALIDACIÓN CRÍTICA: Verificar que inicial esté entre 1760-2640
var inicial = global.get('inicial');
if (inicial < 1760 || inicial > 2640) {{
    node.error("ERROR CRÍTICO: inicial fuera de rango (1760-2640). Valor: " + inicial + ". Escritura bloqueada.");
    return null;
}}

msg.payload = {{
    value: inicial,
    'fc': 6,
    'unitid': {unitid},
    'address': 56,
    'quantity': 1
}}
msg.topic = "TensionInicial L{unitid}"
return msg;"""
            node['func'] = nuevo_codigo
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación de rango (1760-2640)")
        
        elif fix_type == 'crear_inicial_validacion':
            nuevo_codigo = """// VALIDACIÓN CRÍTICA: Verificar que inicial esté entre 1760-2640
var inicial = msg.payload * 10;
if (inicial < 1760 || inicial > 2640) {
    node.error("ERROR CRÍTICO: inicial fuera de rango (1760-2640). Valor: " + inicial + ". No se guarda.");
    return null;
}
global.set("inicial", inicial);
return msg;"""
            node['func'] = nuevo_codigo
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación de rango (1760-2640)")
        
        elif fix_type == 'var_usage':
            func = node.get('func', '')
            # Reemplazar var por let (más seguro que const para variables que se reasignan)
            func = re.sub(r'\bvar\s+', 'let ', func)
            node['func'] = func
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - 'var' cambiado a 'let'")
        
        elif fix_type == 'debug_active':
            node['active'] = False
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - Debug desactivado")
        
        elif fix_type == 'maxqueue_low':
            node['maxQueue'] = 500000
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - maxQueue aumentado a 500000")
        
        elif fix_type == 'chronos_tz':
            node['timezone'] = 'Europe/Madrid'
            node['timezoneType'] = 'str'
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - Timezone configurado a Europe/Madrid")
        
        elif fix_type == 'strict_equality':
            func = node.get('func', '')
            # Reemplazar == por === y != por !==
            func = func.replace(' == ', ' === ')
            func = func.replace(' != ', ' !== ')
            node['func'] = func
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - '==' cambiado a '==='")
        
        elif fix_type == 'duplicados_reg31':
            func = node.get('func', '')
            # Detectar fase del nodo
            fase = '1'
            if 'L2' in bug['nodo']:
                fase = '2'
            elif 'L3' in bug['nodo']:
                fase = '3'
            # Detectar valor (2 para regulacion, 0 para bypass)
            valor = '2' if 'Regulacion' in bug['nodo'] else '0'
            var_name = f'lastModoL{fase}'
            
            # Añadir protección anti-duplicados al inicio
            proteccion = f'let val = {valor}; if (val !== 0 && val !== 2) {{ node.error("Valor modo inválido: " + val); return null; }} let last = flow.get("{var_name}", "file"); if (last !== undefined && last === val) {{ return null; }} flow.set("{var_name}", val, "file");\\n'
            func = proteccion + func
            node['func'] = func
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - Añadida protección anti-duplicados reg 31")
        
        elif fix_type == 'duplicados_reg32':
            func = node.get('func', '')
            # Detectar fase del nodo
            fase = '1'
            if 'L2' in bug['nodo']:
                fase = '2'
            elif 'L3' in bug['nodo']:
                fase = '3'
            var_name = f'lastConsignaL{fase}'
            
            # Añadir protección anti-duplicados
            proteccion = f"let consigna = global.get('consigna'); if (consigna === undefined || consigna === null || isNaN(consigna) || consigna < 1760 || consigna > 2640) {{ node.error('Consigna inválida: ' + consigna); return null; }} let last = flow.get('{var_name}', 'file'); if (last !== undefined && last === consigna) {{ return null; }} flow.set('{var_name}', consigna, 'file');\\n"
            func = proteccion + func
            node['func'] = func
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - Añadida protección anti-duplicados reg 32")
        
        elif fix_type == 'duplicados_reg55':
            func = node.get('func', '')
            # Detectar fase del nodo
            fase = '1'
            if 'L2' in bug['nodo']:
                fase = '2'
            elif 'L3' in bug['nodo']:
                fase = '3'
            var_name = f'lastEstadoInicialL{fase}'
            
            # Añadir protección anti-duplicados
            proteccion = f"let estadoinicial = global.get('estadoinicial'); if (estadoinicial !== 0 && estadoinicial !== 2) {{ node.error('EstadoInicial inválido: ' + estadoinicial); return null; }} let last = flow.get('{var_name}', 'file'); if (last !== undefined && last === estadoinicial) {{ return null; }} flow.set('{var_name}', estadoinicial, 'file');\\n"
            func = proteccion + func
            node['func'] = func
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - Añadida protección anti-duplicados reg 55")
        
        elif fix_type == 'duplicados_reg56':
            func = node.get('func', '')
            # Detectar fase del nodo
            fase = '1'
            if 'L2' in bug['nodo']:
                fase = '2'
            elif 'L3' in bug['nodo']:
                fase = '3'
            var_name = f'lastInicialL{fase}'
            
            # Añadir protección anti-duplicados
            proteccion = f"let inicial = global.get('inicial'); if (inicial === undefined || inicial === null || isNaN(inicial) || inicial < 1760 || inicial > 2640) {{ node.error('Inicial inválido: ' + inicial); return null; }} let last = flow.get('{var_name}', 'file'); if (last !== undefined && last === inicial) {{ return null; }} flow.set('{var_name}', inicial, 'file');\\n"
            func = proteccion + func
            node['func'] = func
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - Añadida protección anti-duplicados reg 56")
        
        elif fix_type == 'validar_fase':
            func = node.get('func', '')
            validacion = 'let fase = flow.get("fase"); if (fase === undefined || fase < 1 || fase > 3) { node.error("Fase inválida: " + fase); return null; }\\n'
            func = validacion + func
            node['func'] = func
            cambios += 1
            print(f"  [OK] Corregido: {bug['nodo']} - Añadida validación de fase")
        
        elif fix_type == 'flujo_consigna':
            target_id = bug.get('target_id')
            if target_id:
                node['wires'] = [[target_id]]
                cambios += 1
                print(f"  [OK] Corregido: {bug['nodo']} - Reconectado al nodo TensionConsigna")
        
        else:
            print(f"  [!] No hay corrección automática para: {bug['desc']}")
        break

if cambios > 0:
    with open('$FLOWS_FILE', 'w') as f:
        json.dump(flows, f, separators=(',', ':'))
else:
    print("  [!] Este bug requiere corrección manual")
PYFIX
                    
                    if [ $? -eq 0 ]; then
                        echo ""
                        read -p "  ¿Reiniciar Node-RED para aplicar cambios? [s/N]: " REINICIAR
                        if [[ "$REINICIAR" =~ ^[Ss]$ ]]; then
                            echo "  [~] Reiniciando Node-RED..."
                            sudo systemctl restart nodered
                            sleep 3
                            echo "  [OK] Node-RED reiniciado"
                        fi
                    fi
                else
                    echo "  [X] Opción no válida"
                fi
            fi
            
            rm -f /tmp/flow_bugs.json
        fi
        ;;
    3)
        echo ""
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Revisar el JSON (flows.json)"
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
            echo "  [F] Archivo: $FLOWS_FILE"
            FILE_SIZE=$(du -h "$FLOWS_FILE" | cut -f1)
            echo "  [S] Tamaño: $FILE_SIZE"
            echo ""
            echo "  ¿Qué quieres ver?"
            echo ""
            echo "  1) Resumen general (nodos por tipo)"
            echo "  2) Buscar nodo por nombre"
            echo "  3) Ver configuración MQTT"
            echo "  4) Ver configuración Modbus"
            echo "  5) Listar todos los nodos function"
            echo "  6) Ver JSON completo (formateado)"
            echo "  7) 🔍 Detectar posibles fallos"
            echo "  8) 📊 Ver valores hardcodeados"
            echo "  0) Volver"
            echo ""
            read -p "  Opción [0-8]: " JSON_OPT
            
            case $JSON_OPT in
                1)
                    echo ""
                    echo "  ┌─────────────────────────────────────────────┐"
                    echo "  │          RESUMEN DE NODOS                   │"
                    echo "  └─────────────────────────────────────────────┘"
                    echo ""
                    python3 -c "
import json
from collections import Counter

with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)

tipos = Counter(node.get('type', 'unknown') for node in flows)
total = len(flows)

print(f'  Total de nodos: {total}')
print('')
for tipo, count in sorted(tipos.items(), key=lambda x: -x[1])[:20]:
    bar = '█' * min(count, 30)
    print(f'  {tipo:25} {count:4}  {bar}')
if len(tipos) > 20:
    print(f'  ... y {len(tipos) - 20} tipos más')
"
                    ;;
                2)
                    echo ""
                    read -p "  Nombre a buscar: " SEARCH_NAME
                    echo ""
                    python3 -c "
import json

with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)

search = '$SEARCH_NAME'.lower()
found = 0

for node in flows:
    name = node.get('name', '')
    if name and search in name.lower():
        found += 1
        print(f\"  [{node.get('type', '?'):15}] {name}\")
        print(f\"      ID: {node.get('id', '?')}\")
        if node.get('func'):
            func_code = node['func']
            lines = func_code.split('\\n')
            print(f\"      Código: {len(lines)} líneas\")
            print('')
            print('  ┌─── CÓDIGO ───────────────────────────────────┐')
            for i, line in enumerate(lines[:50], 1):
                # Truncar líneas muy largas
                if len(line) > 60:
                    line = line[:57] + '...'
                print(f'  │ {i:3}: {line}')
            if len(lines) > 50:
                print(f'  │ ... ({len(lines) - 50} líneas más)')
            print('  └─────────────────────────────────────────────┘')
        print('')

if found == 0:
    print(f'  No se encontraron nodos con \"{search}\"')
else:
    print(f'  Total encontrados: {found}')
"
                    ;;
                3)
                    echo ""
                    echo "  ┌─────────────────────────────────────────────┐"
                    echo "  │          CONFIGURACIÓN MQTT                 │"
                    echo "  └─────────────────────────────────────────────┘"
                    echo ""
                    python3 -c "
import json

with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)

for node in flows:
    if node.get('type') == 'mqtt-broker':
        print(f\"  Broker:     {node.get('broker', '?')}\")
        print(f\"  Puerto:     {node.get('port', '?')}\")
        print(f\"  Client ID:  {node.get('clientid', '?')}\")
        print(f\"  TLS:        {node.get('tls', '?')}\")
        print(f\"  ID:         {node.get('id', '?')}\")
        print('')
    elif node.get('type') == 'mqtt out':
        print(f\"  [MQTT OUT] {node.get('name', 'Sin nombre')}\")
        print(f\"      Topic: {node.get('topic', '?')}\")
        print(f\"      QoS:   {node.get('qos', '?')}\")
        print('')
    elif node.get('type') == 'mqtt in':
        print(f\"  [MQTT IN] {node.get('name', 'Sin nombre')}\")
        print(f\"      Topic: {node.get('topic', '?')}\")
        print(f\"      QoS:   {node.get('qos', '?')}\")
        print('')
"
                    ;;
                4)
                    echo ""
                    echo "  ┌─────────────────────────────────────────────┐"
                    echo "  │          CONFIGURACIÓN MODBUS               │"
                    echo "  └─────────────────────────────────────────────┘"
                    echo ""
                    python3 -c "
import json

with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)

for node in flows:
    if node.get('type') == 'modbus-client':
        print('  [MODBUS CLIENT]')
        print(f\"      Puerto serial:         {node.get('serialPort', '?')}\")
        print(f\"      Baud rate:             {node.get('serialBaudrate', '?')}\")
        print(f\"      Client Timeout:        {node.get('clientTimeout', '?')}ms\")
        print(f\"      Reconnect Timeout:     {node.get('reconnectTimeout', '?')}ms\")
        print(f\"      Command Delay:         {node.get('commandDelay', '?')}ms\")
        print(f\"      Serial Conn Delay:     {node.get('serialConnectionDelay', '?')}ms\")
        print(f\"      ID:                    {node.get('id', '?')}\")
        print('')
    elif node.get('type') == 'modbus-read':
        print(f\"  [MODBUS READ] {node.get('name', 'Sin nombre')}\")
        print(f\"      Address:  {node.get('adr', '?')}\")
        print(f\"      Quantity: {node.get('quantity', '?')}\")
        print(f\"      FC:       {node.get('fc', '?')}\")
        print('')
    elif node.get('type') == 'modbus-write':
        print(f\"  [MODBUS WRITE] {node.get('name', 'Sin nombre')}\")
        print(f\"      Address:  {node.get('adr', '?')}\")
        print(f\"      Quantity: {node.get('quantity', '?')}\")
        print(f\"      FC:       {node.get('fc', '?')}\")
        print('')
"
                    ;;
                5)
                    echo ""
                    echo "  ┌─────────────────────────────────────────────┐"
                    echo "  │          NODOS FUNCTION                     │"
                    echo "  └─────────────────────────────────────────────┘"
                    echo ""
                    python3 -c "
import json

with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)

functions = []
for node in flows:
    if node.get('type') == 'function':
        name = node.get('name', 'Sin nombre')
        func = node.get('func', '')
        lines = len(func.split('\\n')) if func else 0
        functions.append((name, lines, node.get('id', '?')))

functions.sort(key=lambda x: -x[1])

print(f'  Total funciones: {len(functions)}')
print('')
for name, lines, nid in functions:
    print(f'  {lines:4} líneas  │  {name}')
"
                    ;;
                6)
                    echo ""
                    echo "  [~] Mostrando JSON formateado (primeras 100 líneas)..."
                    echo ""
                    python3 -c "
import json

with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)

formatted = json.dumps(flows, indent=2, ensure_ascii=False)
lines = formatted.split('\\n')[:100]
for line in lines:
    print(line)
if len(formatted.split('\\n')) > 100:
    print('...')
    print(f'  [!] Mostrando 100 de {len(formatted.split(chr(10)))} líneas')
    print('')
    print('  Para ver el archivo completo:')
    print(f'  cat \"$FLOWS_FILE\" | python3 -m json.tool | less')
"
                    ;;
                7)
                    echo ""
                    echo "  ┌─────────────────────────────────────────────┐"
                    echo "  │       🔍 DETECTAR POSIBLES FALLOS           │"
                    echo "  └─────────────────────────────────────────────┘"
                    echo ""
                    python3 - "$FLOWS_FILE" << 'PYCHECK'
import json
import sys

flows_file = sys.argv[1]

try:
    with open(flows_file, 'r') as f:
        content = f.read()
except Exception as e:
    print(f'  [X] Error leyendo archivo: {e}')
    sys.exit(1)

# 1. Validar JSON
print('  [1/7] Validando sintaxis JSON...')
try:
    flows = json.loads(content)
    print('  [OK] JSON válido')
except json.JSONDecodeError as e:
    print(f'  [X] JSON INVÁLIDO: {e}')
    print(f'      Línea: {e.lineno}, Columna: {e.colno}')
    sys.exit(1)

print('')
problemas = []

# 2. Recopilar IDs
print('  [2/7] Analizando estructura de nodos...')
all_ids = set()
node_by_id = {}
for node in flows:
    nid = node.get('id')
    if nid:
        if nid in all_ids:
            problemas.append(('ALTO', f"ID duplicado: {nid}"))
        all_ids.add(nid)
        node_by_id[nid] = node
print(f'  [OK] {len(all_ids)} nodos encontrados')

# 3. Verificar conexiones (wires)
print('')
print('  [3/7] Verificando conexiones (wires)...')
wires_rotos = 0
for node in flows:
    wires = node.get('wires', [])
    for output in wires:
        for target_id in output:
            if target_id not in all_ids:
                wires_rotos += 1
                problemas.append(('MEDIO', f"Conexión rota en '{node.get('name', node.get('id'))}' -> {target_id}"))
if wires_rotos == 0:
    print('  [OK] Todas las conexiones válidas')
else:
    print(f'  [!] {wires_rotos} conexiones rotas')

# 4. Nodos huérfanos (sin conexiones entrantes ni salientes, excepto tabs/subflows)
print('')
print('  [4/7] Buscando nodos huérfanos...')
excluir_tipos = {'tab', 'subflow', 'mqtt-broker', 'modbus-client', 'comment', 'ui_tab', 'ui_group', 'ui_base', 'ui_spacer'}
conectados = set()
for node in flows:
    wires = node.get('wires', [])
    for output in wires:
        for target_id in output:
            conectados.add(target_id)
            conectados.add(node.get('id'))

huerfanos = []
for node in flows:
    nid = node.get('id')
    ntype = node.get('type', '')
    if ntype not in excluir_tipos and nid not in conectados:
        # Verificar si es un nodo de entrada (inject, mqtt in, etc.)
        if ntype not in {'inject', 'mqtt in', 'http in', 'websocket in', 'tcp in', 'udp in', 'modbus-read'}:
            huerfanos.append(node)

if not huerfanos:
    print('  [OK] No hay nodos huérfanos')
else:
    print(f'  [!] {len(huerfanos)} nodos sin conexiones:')
    for h in huerfanos[:5]:
        problemas.append(('BAJO', f"Nodo huérfano: [{h.get('type')}] {h.get('name', 'Sin nombre')}"))
    if len(huerfanos) > 5:
        print(f'      ... y {len(huerfanos) - 5} más')

# 5. Funciones con errores potenciales
print('')
print('  [5/7] Analizando funciones JavaScript...')
func_problemas = 0
for node in flows:
    if node.get('type') == 'function':
        func = node.get('func', '')
        name = node.get('name', 'Sin nombre')
        
        # Función vacía
        if not func.strip():
            problemas.append(('MEDIO', f"Función vacía: {name}"))
            func_problemas += 1
        
        # return sin msg
        if 'return;' in func and 'return msg' not in func and 'return null' not in func:
            problemas.append(('BAJO', f"Función con 'return;' sin valor: {name}"))
            func_problemas += 1
        
        # console.log en producción
        if 'console.log' in func:
            problemas.append(('BAJO', f"console.log en producción: {name}"))
            func_problemas += 1
        
        # Variables no declaradas comunes
        if 'undeclared' in func.lower() or 'undefined' in func and 'typeof' not in func:
            pass  # Ignorar, puede ser intencional

if func_problemas == 0:
    print('  [OK] Funciones sin problemas obvios')
else:
    print(f'  [!] {func_problemas} problemas en funciones')

# 6. Configuración crítica
print('')
print('  [6/7] Verificando configuración crítica...')
mqtt_ok = False
modbus_ok = False
for node in flows:
    if node.get('type') == 'mqtt-broker':
        broker = node.get('broker', '')
        if broker:
            mqtt_ok = True
            if not broker.startswith(('mqtt', 'localhost', '127.0.0.1', '57.129')):
                problemas.append(('MEDIO', f"Broker MQTT sospechoso: {broker}"))
    
    if node.get('type') == 'modbus-client':
        modbus_ok = True
        timeout = node.get('clientTimeout', 0)
        if isinstance(timeout, int) and timeout < 500:
            problemas.append(('ALTO', f"Timeout Modbus muy bajo: {timeout}ms"))
        serial = node.get('serialPort', '')
        if not serial:
            problemas.append(('ALTO', 'Puerto serial Modbus no configurado'))

if mqtt_ok:
    print('  [OK] MQTT configurado')
else:
    problemas.append(('MEDIO', 'No hay broker MQTT configurado'))
    print('  [!] No hay broker MQTT')

if modbus_ok:
    print('  [OK] Modbus configurado')
else:
    print('  [~] No hay cliente Modbus (puede ser normal)')

# 7. Subflows sin definición
print('')
print('  [7/7] Verificando subflows...')
subflow_defs = set()
subflow_uses = set()
for node in flows:
    if node.get('type') == 'subflow':
        subflow_defs.add(node.get('id'))
    elif node.get('type', '').startswith('subflow:'):
        subflow_id = node.get('type').replace('subflow:', '')
        subflow_uses.add(subflow_id)

missing_subflows = subflow_uses - subflow_defs
if missing_subflows:
    for sf in missing_subflows:
        problemas.append(('ALTO', f"Subflow usado pero no definido: {sf}"))
    print(f'  [X] {len(missing_subflows)} subflows sin definición')
else:
    print('  [OK] Todos los subflows definidos')

# === RESUMEN ===
print('')
print('  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
print('  RESUMEN DE PROBLEMAS')
print('  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
print('')

if not problemas:
    print('  ✅ No se encontraron problemas')
else:
    altos = [p for p in problemas if p[0] == 'ALTO']
    medios = [p for p in problemas if p[0] == 'MEDIO']
    bajos = [p for p in problemas if p[0] == 'BAJO']
    
    print(f'  🔴 Críticos: {len(altos)}')
    print(f'  🟡 Medios:   {len(medios)}')
    print(f'  🟢 Bajos:    {len(bajos)}')
    print('')
    
    if altos:
        print('  ─── CRÍTICOS ───')
        for _, desc in altos:
            print(f'  🔴 {desc}')
        print('')
    
    if medios:
        print('  ─── MEDIOS ───')
        for _, desc in medios:
            print(f'  🟡 {desc}')
        print('')
    
    if bajos:
        print('  ─── BAJOS ───')
        for _, desc in bajos[:10]:
            print(f'  🟢 {desc}')
        if len(bajos) > 10:
            print(f'  ... y {len(bajos) - 10} más')

print('')
PYCHECK
                    ;;
                8)
                    echo ""
                    echo "  ┌─────────────────────────────────────────────┐"
                    echo "  │       📊 VALORES HARDCODEADOS               │"
                    echo "  └─────────────────────────────────────────────┘"
                    echo ""
                    python3 -c "
import json
import re

with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)

valores = {}

for node in flows:
    if node.get('type') == 'function':
        func = node.get('func', '')
        name = node.get('name', 'Sin nombre')
        
        # Buscar números de 4+ dígitos
        numeros = re.findall(r'\b(\d{4,})\b', func)
        for num in numeros:
            num_val = int(num)
            if num_val not in valores:
                valores[num_val] = []
            if name not in valores[num_val]:
                valores[num_val].append(name)

# Ordenar por valor
print(f'  Total valores encontrados: {len(valores)}')
print('')

# Valores conocidos
conocidos = {
    1760: 'Tensión mínima (176V x10)',
    2640: 'Tensión máxima (264V x10)',
    1000: 'Timeout 1 segundo',
    2000: 'Timeout 2 segundos',
    3000: 'Timeout 3 segundos',
    5000: 'Timeout 5 segundos',
    10000: '10 segundos',
    32768: '0x8000 - Bit de signo',
    43981: '0xABCD - Patrón verificación',
    47818: 'Patrón verificación Modbus',
    51914: '0xCACA - Patrón verificación',
    65535: '0xFFFF - Máximo 16 bits',
    86400: 'Segundos en 24 horas',
    300000: '5 minutos en ms',
    600000: '10 minutos en ms',
}

for val in sorted(valores.keys()):
    funciones = valores[val]
    desc = conocidos.get(val, '')
    
    if desc:
        print(f'  {val:>8}  ✓ {desc}')
    else:
        print(f'  {val:>8}  ? Desconocido')
    
    for f in funciones[:3]:
        print(f'             └─ {f}')
    if len(funciones) > 3:
        print(f'             └─ ... y {len(funciones) - 3} más')
    print('')
"
                    ;;
                0|*)
                    echo "  Volviendo..."
                    ;;
            esac
        fi
        ;;
    4)
        # Actualizar software
        echo ""
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Actualizar software"
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        # Detectar directorio del repo
        REPO_DIR=""
        for d in ~/rpi-azure-bridge /home/*/rpi-azure-bridge; do
            if [ -d "$d/.git" ]; then
                REPO_DIR="$d"
                break
            fi
        done
        
        if [ -z "$REPO_DIR" ]; then
            echo "  [X] No se encontró el repositorio"
        else
            echo "  [~] Actualizando desde GitHub..."
            cd "$REPO_DIR"
            git fetch --all 2>/dev/null
            git reset --hard origin/main 2>/dev/null
            echo "  [OK] Software actualizado"
            echo ""
            echo "  [~] Reiniciando Node-RED..."
            sudo systemctl restart nodered 2>/dev/null || true
            echo "  [OK] Node-RED reiniciado"
        fi
        ;;
    5)
        # Reparar placas desparametrizadas
        echo ""
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Reparar placas desparametrizadas"
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        REPAIR_SCRIPT="/tmp/gesinne-reparar.sh"
        curl -sSL "https://raw.githubusercontent.com/Gesinne/rpi-azure-bridge/main/firmware.sh" -o "$REPAIR_SCRIPT" 2>/dev/null
        
        if [ -f "$REPAIR_SCRIPT" ]; then
            chmod +x "$REPAIR_SCRIPT"
            sudo bash "$REPAIR_SCRIPT" reparar
        else
            echo "  [X] Error descargando script de reparación"
        fi
        ;;
    6)
        # Activar persistencia de variables (anti-desparametrización)
        echo ""
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Activar persistencia de variables"
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  Esto configura Node-RED para guardar las variables"
        echo "  globales en disco, evitando que se pierdan al reiniciar."
        echo ""
        
        SETTINGS_FILE="/home/gesinne/.node-red/settings.js"
        
        # Verificar si ya está configurado
        if grep -q 'module: "localfilesystem"' "$SETTINGS_FILE" 2>/dev/null && grep -B2 'module: "localfilesystem"' "$SETTINGS_FILE" | grep -q 'default:'; then
            echo "  [OK] La persistencia ya está activada"
        else
            echo "  [~] Configurando persistencia..."
            
            # Backup
            sudo cp "$SETTINGS_FILE" "${SETTINGS_FILE}.backup.$(date +%Y%m%d%H%M%S)"
            
            # Método simple: reemplazar solo la línea module: "memory" dentro de default
            # Buscar la línea exacta y reemplazarla
            if grep -q 'module: "memory"' "$SETTINGS_FILE"; then
                sudo sed -i '0,/module: "memory"/{s/module: "memory"/module: "localfilesystem"/}' "$SETTINGS_FILE"
                
                # Verificar que el cambio se aplicó
                if grep -q 'module: "localfilesystem"' "$SETTINGS_FILE"; then
                    echo "  [OK] Configuración actualizada"
                    
                    echo ""
                    echo "  [~] Reiniciando Node-RED para aplicar cambios..."
                    sudo systemctl restart nodered
                    sleep 5
                    
                    # Verificar que Node-RED inició correctamente
                    if sudo systemctl is-active --quiet nodered; then
                        echo "  [OK] Node-RED reiniciado correctamente"
                        echo ""
                        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                        echo "  [OK] Persistencia activada"
                        echo "      Las variables globales ahora se guardan en disco"
                        echo "      y sobrevivirán a reinicios de Node-RED y la RPi"
                        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    else
                        echo "  [X] Error: Node-RED no inició correctamente"
                        echo "  [~] Restaurando backup..."
                        BACKUP_FILE=$(ls -t ${SETTINGS_FILE}.backup.* 2>/dev/null | head -1)
                        if [ -n "$BACKUP_FILE" ]; then
                            sudo cp "$BACKUP_FILE" "$SETTINGS_FILE"
                            sudo systemctl restart nodered
                            echo "  [OK] Backup restaurado"
                        fi
                    fi
                else
                    echo "  [X] Error aplicando cambio"
                fi
            else
                echo "  [!] No se encontró configuración de memoria para cambiar"
                echo "      El archivo puede tener un formato diferente"
            fi
        fi
        ;;
    0|*)
        echo "  Saliendo..."
        ;;
esac

echo ""
read -p "  Presiona Enter para continuar..."
