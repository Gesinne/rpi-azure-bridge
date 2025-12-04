#!/bin/bash
#
# Instalador automático del puente MQTT → Azure IoT Hub
# Uso: wget -qO- https://raw.githubusercontent.com/Gesinne/rpi-azure-bridge/main/install.sh > /tmp/install.sh && sudo bash /tmp/install.sh
#

set -e

clear
echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║                                              ║"
echo "  ║   INSTALADOR GESINNE - Azure IoT Bridge      ║"
echo "  ║                                              ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""

# Verificar que se ejecuta como root
if [ "$EUID" -ne 0 ]; then
    echo "  ❌ ERROR: Ejecutar con sudo"
    echo ""
    echo "  Usa: curl -sSL https://raw.githubusercontent.com/Gesinne/rpi-azure-bridge/main/install.sh | sudo bash"
    echo ""
    exit 1
fi

# Detectar si ya está instalado
INSTALL_DIR="/home/$(logname 2>/dev/null || echo 'pi')/rpi-azure-bridge"
OVERRIDE_FILE="$INSTALL_DIR/docker-compose.override.yml"

# Función para mostrar config de Node-RED
show_nodered_config() {
    USER_HOME="/home/$(logname 2>/dev/null || echo 'pi')"
    for f in "$USER_HOME/.node-red/flows.json" "/home/pi/.node-red/flows.json" "/home/gesinne/.node-red/flows.json"; do
        if [ -f "$f" ]; then
            FLOWS_FILE="$f"
            break
        fi
    done
    
    if [ -n "$FLOWS_FILE" ]; then
        BROKER_INFO=$(python3 -c "
import json
try:
    with open('$FLOWS_FILE', 'r') as f:
        flows = json.load(f)
    for node in flows:
        if node.get('type') == 'mqtt-broker':
            broker = node.get('broker', '?')
            port = node.get('port', '?')
            tls = '🔒 SSL' if node.get('usetls') else '🔓 Sin SSL'
            print(f'{broker}:{port} {tls}')
            break
except:
    print('No detectado')
" 2>/dev/null)
        echo "  📡 Node-RED MQTT: $BROKER_INFO"
    else
        echo "  📡 Node-RED: No detectado"
    fi
}

if [ -f "$OVERRIDE_FILE" ]; then
    echo "  ✅ Bridge Azure IoT instalado"
    show_nodered_config
    echo ""
    echo "  ¿Qué deseas hacer?"
    echo ""
    echo "  1) Actualizar software (mantener configuración actual)"
    echo "  2) Cambiar a modo Azure IoT (nueva connection string)"
    echo "  3) Cambiar a modo Servidor Remoto (mqtt.gesinne.cloud)"
    echo "  4) Ver estado actual"
    echo "  5) Actualizar Flow Node-RED"
    echo "  6) Restaurar Flow anterior (backup)"
    echo "  7) Modificar configuración equipo"
    echo "  8) Leer registros Modbus"
    echo "  9) Salir"
    echo ""
    read -p "  Opción [1-9]: " OPTION
    
    case $OPTION in
        1)
            echo ""
            echo "  📥 Actualizando..."
            cd "$INSTALL_DIR"
            git stash -q 2>/dev/null || true
            git fetch -q origin main
            git reset --hard origin/main -q
            docker-compose down 2>/dev/null || true
            docker-compose up -d --build
            echo ""
            echo "  ✅ Actualización completada"
            echo ""
            sleep 3
            docker-compose logs --tail=10
            exit 0
            ;;
        2)
            CONNECTION_MODE="1"
            ;;
        3)
            CONNECTION_MODE="2"
            ;;
        4)
            echo ""
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Estado actual"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
            # Mostrar config del equipo desde archivo de configuración
            CONFIG_FILE=""
            for f in /home/*/config/equipo_config.json; do
                if [ -f "$f" ]; then
                    CONFIG_FILE="$f"
                    break
                fi
            done
            
            if [ -n "$CONFIG_FILE" ]; then
                python3 -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        data = json.load(f)
    print(f\"  🔧 Serie: {data.get('serie', '?')}\")
    print(f\"  ⚡ Potencia: {data.get('potencia', '?')} kW\")
    print(f\"  🔌 Imax: {data.get('Imax', '?')} A\")
except:
    pass
" 2>/dev/null
            fi
            
            # Mostrar versión y firmware desde Node-RED
            for flowfile in /home/*/.node-red/flows.json; do
                if [ -f "$flowfile" ]; then
                    python3 -c "
import json, re
try:
    with open('$flowfile') as file:
        flows = json.load(file)
    
    # Buscar versión en varios nodos posibles
    version_found = False
    for node in flows:
        name = node.get('name', '')
        func = node.get('func', '')
        if name in ['Editar lo necesario', 'Establecer valores globales', 'No tocar'] or 'Version' in func:
            match = re.search(r'([0-9]{4}_[0-9]{2}_[0-9]{2}_[a-zA-Z0-9]+)', func)
            if match:
                print(f'  📋 Versión Flow: {match.group(1)}')
                version_found = True
                break
    
    if not version_found:
        # Buscar en todo el archivo
        with open('$flowfile') as file:
            content = file.read()
        match = re.search(r'([0-9]{4}_[0-9]{2}_[0-9]{2}_[a-zA-Z0-9]+)', content)
        if match:
            print(f'  📋 Versión Flow: {match.group(1)}')
except Exception as e:
    pass
" 2>/dev/null
                    break
                fi
            done
            
            # Mostrar firmware desde global context de Node-RED
            for g in /home/*/.node-red/context/global/global.json; do
                if [ -f "$g" ]; then
                    python3 -c "
import json
try:
    with open('$g') as f:
        data = json.load(f)
    fw1 = data.get('firmwareL1', '?')
    fw2 = data.get('firmwareL2', '?')
    fw3 = data.get('firmwareL3', '?')
    print(f'  📦 Firmware: L1={fw1} L2={fw2} L3={fw3}')
except:
    pass
" 2>/dev/null
                    break
                fi
            done
            
            # Mostrar espacio en disco
            DISK_INFO=$(df -h / | tail -1 | awk '{print $2, $3, $4, $5}')
            TOTAL=$(echo $DISK_INFO | cut -d' ' -f1)
            USADO=$(echo $DISK_INFO | cut -d' ' -f2)
            LIBRE=$(echo $DISK_INFO | cut -d' ' -f3)
            PORCENTAJE=$(echo $DISK_INFO | cut -d' ' -f4)
            echo "  💾 Disco: ${USADO}/${TOTAL} usado (${LIBRE} libre) ${PORCENTAJE}"
            
            show_nodered_config
            echo ""
            cd "$INSTALL_DIR" 2>/dev/null
            if docker-compose ps 2>/dev/null | grep -q "Up"; then
                echo "  🟢 Bridge Docker: Corriendo"
            else
                echo "  🔴 Bridge Docker: Parado"
            fi
            echo ""
            echo "  📋 Healthcheck:"
            curl -s http://localhost:8080/health 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    azure = '🟢' if d.get('azure_connected') else '🔴'
    mqtt = '🟢' if d.get('mqtt_connected') else '🔴'
    print(f'  {azure} Azure IoT Hub')
    print(f'  {mqtt} MQTT Local')
    print(f'  📊 Mensajes enviados: {d.get(\"messages_sent\", 0)}')
    print(f'  💾 Buffer offline: {d.get(\"offline_buffer_size\", 0)}')
except:
    print('  ⚠️  No disponible')
" 2>/dev/null
            echo ""
            echo "  📋 Últimos logs:"
            docker-compose logs --tail=5 2>/dev/null | grep -E "✅|❌|📤|⚠️|Conectado" | tail -5
            echo ""
            exit 0
            ;;
        5)
            echo ""
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Actualizar Flow Node-RED"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
            CACHE_DIR="/opt/nodered-flows-cache"
            CREDS_FILE="/opt/nodered-flows-cache/.git_credentials"
            
            # Verificar si hay credenciales guardadas
            if [ -f "$CREDS_FILE" ]; then
                source "$CREDS_FILE"
                echo "  🔐 Usando credenciales guardadas (usuario: $GIT_USER)"
                echo ""
                read -p "  ¿Usar estas credenciales? [S/n]: " USE_SAVED
                if [ "$USE_SAVED" = "n" ] || [ "$USE_SAVED" = "N" ]; then
                    GIT_USER=""
                    GIT_TOKEN=""
                fi
            fi
            
            # Solicitar credenciales si no hay guardadas
            if [ -z "$GIT_USER" ] || [ -z "$GIT_TOKEN" ]; then
                echo "  🔐 Credenciales de GitHub (repo privado)"
                echo ""
                read -p "  Usuario GitHub: " GIT_USER
                read -s -p "  Token/Contraseña: " GIT_TOKEN
                echo ""
                
                if [ -z "$GIT_USER" ] || [ -z "$GIT_TOKEN" ]; then
                    echo "  ❌ Usuario y token son requeridos"
                    exit 1
                fi
                
                # Guardar credenciales para próximas veces
                sudo mkdir -p "$CACHE_DIR" 2>/dev/null
                echo "GIT_USER=\"$GIT_USER\"" | sudo tee "$CREDS_FILE" > /dev/null
                echo "GIT_TOKEN=\"$GIT_TOKEN\"" | sudo tee -a "$CREDS_FILE" > /dev/null
                sudo chmod 600 "$CREDS_FILE"
                echo "  💾 Credenciales guardadas"
            fi
            
            NODERED_REPO="https://${GIT_USER}:${GIT_TOKEN}@github.com/Gesinne/NODERED.git"
            
            # Usar caché o clonar
            echo ""
            echo "  📥 Obteniendo versiones disponibles..."
            
            if [ -d "$CACHE_DIR/.git" ]; then
                # Ya existe, actualizar
                cd "$CACHE_DIR"
                git remote set-url origin "$NODERED_REPO" 2>/dev/null
                if ! git pull -q 2>/dev/null; then
                    echo "  ⚠️  Error actualizando, re-clonando..."
                    rm -rf "$CACHE_DIR"
                    if ! git clone -q --depth 1 "$NODERED_REPO" "$CACHE_DIR" 2>/dev/null; then
                        echo "  ❌ Error accediendo al repositorio"
                        echo "  Verifica usuario y token"
                        exit 1
                    fi
                fi
            else
                # Primera vez, clonar
                sudo mkdir -p "$CACHE_DIR" 2>/dev/null
                sudo chown $(whoami) "$CACHE_DIR" 2>/dev/null
                if ! git clone -q --depth 1 "$NODERED_REPO" "$CACHE_DIR" 2>/dev/null; then
                    echo "  ❌ Error accediendo al repositorio"
                    echo "  Verifica usuario y token"
                    exit 1
                fi
            fi
            
            TEMP_DIR="$CACHE_DIR"
            
            # Obtener versión actual instalada (buscar específicamente global.set('Version',...))
            CURRENT_VERSION=""
            for flowfile in /home/*/.node-red/flows.json; do
                if [ -f "$flowfile" ]; then
                    CURRENT_VERSION=$(python3 -c "
import re
try:
    with open('$flowfile') as f:
        content = f.read()
    # Buscar específicamente global.set('Version', 'YYYY_MM_DD_xxx')
    match = re.search(r\"global\.set\(['\\\"]Version['\\\"][^'\\\"]*['\\\"]([0-9]{4})_([0-9]{2})_([0-9]{2})\", content)
    if match:
        print(f'{match.group(1)}{match.group(2)}{match.group(3)}')
except:
    pass
" 2>/dev/null)
                    break
                fi
            done
            
            # Detectar tipo de dashboard instalado
            NODERED_MODULES=""
            for d in /home/*/.node-red; do
                if [ -d "$d/node_modules" ]; then
                    NODERED_MODULES="$d/node_modules"
                    NODERED_HOME="$d"
                    break
                fi
            done
            
            # Verificar paquetes COMPLETOS instalados (no solo plugins)
            HAS_FLOWFUSE=$([ -d "$NODERED_MODULES/@flowfuse/node-red-dashboard" ] && echo "yes" || echo "no")
            HAS_CLASSIC=$([ -d "$NODERED_MODULES/node-red-dashboard" ] && echo "yes" || echo "no")
            
            if [ "$HAS_FLOWFUSE" = "yes" ]; then
                echo "  📊 Dashboard actual: FlowFuse (dbrd2)"
            elif [ "$HAS_CLASSIC" = "yes" ]; then
                echo "  📊 Dashboard actual: Clásico"
            else
                echo "  📊 Dashboard actual: Ninguno detectado"
            fi
            
            # Listar TODOS los archivos .json con fecha
            VERSIONS=$(ls "$TEMP_DIR"/*.json 2>/dev/null | xargs -n1 basename | grep -E '^[0-9]{8}' | sort -r)
            
            if [ -z "$VERSIONS" ]; then
                # Si no hay con fecha, mostrar todos
                VERSIONS=$(ls "$TEMP_DIR"/*.json 2>/dev/null | xargs -n1 basename)
            fi
            
            if [ -z "$VERSIONS" ]; then
                echo "  ❌ No se encontraron archivos .json en el repositorio"
                rm -rf "$TEMP_DIR"
                exit 1
            fi
            
            echo ""
            if [ -n "$CURRENT_VERSION" ]; then
                echo "  📋 Versión actual instalada: $CURRENT_VERSION"
            fi
            echo ""
            echo "  Versiones disponibles (iguales o superiores):"
            echo ""
            
            i=1
            declare -a VERSION_ARRAY
            for v in $VERSIONS; do
                # Extraer fecha del nombre del archivo
                FILE_DATE=$(echo "$v" | grep -oE '^[0-9]{8}' || echo "00000000")
                
                # Mostrar solo si es igual o superior a la actual (o si no hay actual)
                if [ -z "$CURRENT_VERSION" ] || [ "$FILE_DATE" -ge "$CURRENT_VERSION" ] 2>/dev/null || [ "$FILE_DATE" = "00000000" ]; then
                    if [ "$FILE_DATE" = "$CURRENT_VERSION" ]; then
                        echo "  $i) $v (actual)"
                    else
                        echo "  $i) $v"
                    fi
                    VERSION_ARRAY[$i]="$v"
                    i=$((i+1))
                fi
            done
            
            if [ $i -eq 1 ]; then
                echo "  ✅ Ya tienes la última versión"
                rm -rf "$TEMP_DIR"
                exit 0
            fi
            
            echo ""
            read -p "  Selecciona versión [1-$((i-1))]: " VERSION_CHOICE
            
            # Determinar archivo del flow
            VERSION_NAME="${VERSION_ARRAY[$VERSION_CHOICE]}"
            if [ -n "$VERSION_NAME" ] && [ -f "$TEMP_DIR/$VERSION_NAME" ]; then
                FLOW_FILE="$TEMP_DIR/$VERSION_NAME"
            else
                FLOW_FILE=""
            fi
            
            if [ -z "$FLOW_FILE" ]; then
                echo "  ❌ Opción no válida"
                rm -rf "$TEMP_DIR"
                exit 1
            fi
            
            # Detectar si el flow seleccionado necesita FlowFuse o Clásico
            # FlowFuse usa nodos tipo "ui-button", "ui-chart" (con guión)
            # Clásico usa nodos tipo "ui_button", "ui_chart" (con guión bajo)
            NEEDS_FLOWFUSE="no"
            if grep -q '"type":\s*"ui-' "$FLOW_FILE" 2>/dev/null; then
                NEEDS_FLOWFUSE="yes"
                echo "  📊 Flow detectado: FlowFuse Dashboard"
            else
                echo "  📊 Flow detectado: Dashboard Clásico"
            fi
            
            # Verificar si necesita cambiar el dashboard
            cd "$NODERED_HOME"
            
            if [ "$NEEDS_FLOWFUSE" = "yes" ]; then
                # Necesita FlowFuse
                if [ "$HAS_FLOWFUSE" = "no" ]; then
                    echo ""
                    echo "  ⚠️  Este flow requiere FlowFuse Dashboard"
                    echo "  Instalando (puede tardar unos minutos)..."
                    echo ""
                    # Desinstalar clásico primero si existe
                    npm uninstall node-red-dashboard 2>/dev/null || true
                    # Instalar FlowFuse
                    npm install @flowfuse/node-red-dashboard --save
                    if [ $? -eq 0 ]; then
                        echo "  ✅ FlowFuse Dashboard instalado"
                    else
                        echo "  ❌ Error instalando FlowFuse Dashboard"
                        exit 1
                    fi
                elif [ "$HAS_CLASSIC" = "yes" ]; then
                    # Tiene ambos, quitar el clásico para evitar conflictos
                    echo ""
                    echo "  ⚠️  Detectados ambos dashboards, limpiando conflicto..."
                    npm uninstall node-red-dashboard 2>/dev/null || true
                    echo "  ✅ Conflicto resuelto"
                fi
            else
                # Necesita Clásico
                if [ "$HAS_CLASSIC" = "no" ]; then
                    echo ""
                    echo "  ⚠️  Este flow requiere Dashboard Clásico"
                    echo "  Instalando (puede tardar unos minutos)..."
                    echo ""
                    # Desinstalar FlowFuse primero si existe
                    npm uninstall @flowfuse/node-red-dashboard 2>/dev/null || true
                    # Instalar clásico
                    npm install node-red-dashboard --save
                    if [ $? -eq 0 ]; then
                        echo "  ✅ Dashboard Clásico instalado"
                    else
                        echo "  ❌ Error instalando Dashboard Clásico"
                        exit 1
                    fi
                elif [ "$HAS_FLOWFUSE" = "yes" ]; then
                    # Tiene ambos, quitar FlowFuse para evitar conflictos
                    echo ""
                    echo "  ⚠️  Detectados ambos dashboards, limpiando conflicto..."
                    npm uninstall @flowfuse/node-red-dashboard 2>/dev/null || true
                    echo "  ✅ Conflicto resuelto"
                fi
            fi
            
            echo ""
            echo "  📥 Instalando $VERSION_NAME..."
            
            # Buscar directorio Node-RED
            NODERED_DIR="$NODERED_HOME"
            
            if [ -z "$NODERED_DIR" ]; then
                echo "  ❌ No se encontró directorio Node-RED"
                exit 1
            fi
            
            # Backup del flow actual
            BACKUP_FILE="$NODERED_DIR/flows.json.backup.$(date +%Y%m%d%H%M%S)"
            cp "$NODERED_DIR/flows.json" "$BACKUP_FILE"
            echo "  💾 Backup creado: $BACKUP_FILE"
            
            # Guardar configuración MQTT actual antes de sobrescribir
            MQTT_CONFIG=$(python3 -c "
import json
try:
    with open('$NODERED_DIR/flows.json', 'r') as f:
        flows = json.load(f)
    for node in flows:
        if node.get('type') == 'mqtt-broker':
            print(json.dumps({
                'broker': node.get('broker', 'localhost'),
                'port': node.get('port', '1883'),
                'usetls': node.get('usetls', False)
            }))
            break
except:
    pass
" 2>/dev/null)
            
            # Verificar que es JSON válido e instalar
            if python3 -c "import json; json.load(open('$FLOW_FILE'))" 2>/dev/null; then
                cp "$FLOW_FILE" "$NODERED_DIR/flows.json"
                
                # Restaurar configuración MQTT si existía
                if [ -n "$MQTT_CONFIG" ]; then
                    python3 -c "
import json
mqtt_config = json.loads('$MQTT_CONFIG')
with open('$NODERED_DIR/flows.json', 'r') as f:
    flows = json.load(f)
for node in flows:
    if node.get('type') == 'mqtt-broker':
        node['broker'] = mqtt_config['broker']
        node['port'] = mqtt_config['port']
        node['usetls'] = mqtt_config['usetls']
with open('$NODERED_DIR/flows.json', 'w') as f:
    json.dump(flows, f, indent=4)
" 2>/dev/null
                    echo "  ✅ Flow instalado: $VERSION_NAME"
                    echo "  🔗 Configuración MQTT preservada: ${MQTT_CONFIG}"
                else
                    echo "  ✅ Flow instalado: $VERSION_NAME"
                fi
                echo ""
                echo "  🔄 Reiniciando Node-RED..."
                sudo systemctl restart nodered
                sleep 5
                echo "  ✅ Node-RED reiniciado"
                
                # Reiniciar kiosko si existe
                if systemctl is-active --quiet kiosk.service 2>/dev/null; then
                    echo ""
                    echo "  🔄 Reiniciando modo kiosko..."
                    sudo systemctl restart kiosk.service
                    sleep 2
                    echo "  ✅ Kiosko reiniciado"
                fi
            else
                echo "  ❌ Error: El archivo no es JSON válido"
                exit 1
            fi
            
            # Buscar y mostrar equipo_config.json
            CONFIG_FILE=""
            for f in /home/*/config/equipo_config.json; do
                if [ -f "$f" ]; then
                    CONFIG_FILE="$f"
                    break
                fi
            done
            
            echo ""
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Configuración del equipo"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
            if [ -n "$CONFIG_FILE" ]; then
                python3 -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        data = json.load(f)
    print(f\"  Serie:     {data.get('serie', '?')}\")
    print(f\"  Potencia:  {data.get('potencia', '?')} kW\")
    print(f\"  Imax:      {data.get('Imax', '?')} A\")
    print(f\"  Tramo 1:   {data.get('tramo1', '?')}\")
    print(f\"  Tramo 2:   {data.get('tramo2', '?')}\")
    print(f\"  Tramo 3:   {data.get('tramo3', '?')}\")
    print(f\"  Tramo 4:   {data.get('tramo4', '?')}\")
except Exception as e:
    print(f'  Error leyendo config: {e}')
" 2>/dev/null
                echo ""
                read -p "  ¿Modificar configuración? [s/N]: " MODIFY_CONFIG
                
                if [ "$MODIFY_CONFIG" = "s" ] || [ "$MODIFY_CONFIG" = "S" ]; then
                    echo ""
                    
                    # Leer valores actuales
                    CURRENT=$(python3 -c "
import json
with open('$CONFIG_FILE') as f:
    d = json.load(f)
print(d.get('serie',''))
print(d.get('potencia',''))
print(d.get('Imax',''))
print(d.get('tramo1',''))
print(d.get('tramo2',''))
print(d.get('tramo3',''))
print(d.get('tramo4',''))
" 2>/dev/null)
                    
                    OLD_SERIE=$(echo "$CURRENT" | sed -n '1p')
                    OLD_POTENCIA=$(echo "$CURRENT" | sed -n '2p')
                    OLD_IMAX=$(echo "$CURRENT" | sed -n '3p')
                    OLD_T1=$(echo "$CURRENT" | sed -n '4p')
                    OLD_T2=$(echo "$CURRENT" | sed -n '5p')
                    OLD_T3=$(echo "$CURRENT" | sed -n '6p')
                    OLD_T4=$(echo "$CURRENT" | sed -n '7p')
                    
                    read -p "  Serie [$OLD_SERIE]: " NEW_SERIE
                    read -p "  Potencia kW [$OLD_POTENCIA]: " NEW_POTENCIA
                    read -p "  Imax A [$OLD_IMAX]: " NEW_IMAX
                    read -p "  Tramo 1 [$OLD_T1]: " NEW_T1
                    read -p "  Tramo 2 [$OLD_T2]: " NEW_T2
                    read -p "  Tramo 3 [$OLD_T3]: " NEW_T3
                    read -p "  Tramo 4 [$OLD_T4]: " NEW_T4
                    
                    # Usar valores anteriores si no se introducen nuevos
                    NEW_SERIE="${NEW_SERIE:-$OLD_SERIE}"
                    NEW_POTENCIA="${NEW_POTENCIA:-$OLD_POTENCIA}"
                    NEW_IMAX="${NEW_IMAX:-$OLD_IMAX}"
                    NEW_T1="${NEW_T1:-$OLD_T1}"
                    NEW_T2="${NEW_T2:-$OLD_T2}"
                    NEW_T3="${NEW_T3:-$OLD_T3}"
                    NEW_T4="${NEW_T4:-$OLD_T4}"
                    
                    # Guardar nueva configuración
                    python3 -c "
import json
with open('$CONFIG_FILE') as f:
    data = json.load(f)
data['serie'] = '$NEW_SERIE'
data['potencia'] = int('$NEW_POTENCIA')
data['Imax'] = int('$NEW_IMAX')
data['tramo1'] = int('$NEW_T1')
data['tramo2'] = int('$NEW_T2')
data['tramo3'] = int('$NEW_T3')
data['tramo4'] = int('$NEW_T4')
with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=4)
" 2>/dev/null
                    
                    echo ""
                    echo "  ✅ Configuración guardada"
                    echo ""
                    echo "  🔄 Reiniciando Node-RED para aplicar cambios..."
                    sudo systemctl restart nodered
                    sleep 2
                    echo "  ✅ Node-RED reiniciado"
                    
                    # Reiniciar kiosko si existe
                    if systemctl is-active --quiet kiosk.service 2>/dev/null; then
                        echo ""
                        echo "  🔄 Reiniciando modo kiosko..."
                        sudo systemctl restart kiosk.service
                        sleep 2
                        echo "  ✅ Kiosko reiniciado"
                    fi
                fi
            else
                echo "  ⚠️  No se encontró equipo_config.json"
                echo "  Crea el archivo en: /home/gesinne/config/equipo_config.json"
            fi
            
            exit 0
            ;;
        6)
            echo ""
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Restaurar Flow anterior"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
            # Buscar backups
            NODERED_DIR=""
            for d in /home/*/.node-red; do
                if [ -d "$d" ]; then
                    NODERED_DIR="$d"
                    break
                fi
            done
            
            if [ -z "$NODERED_DIR" ]; then
                echo "  ❌ No se encontró directorio Node-RED"
                exit 1
            fi
            
            BACKUPS=$(ls -t "$NODERED_DIR"/flows.json.backup.* 2>/dev/null)
            
            if [ -z "$BACKUPS" ]; then
                echo "  ❌ No hay backups disponibles"
                exit 1
            fi
            
            echo "  Backups disponibles (más reciente primero):"
            echo ""
            
            i=1
            declare -a BACKUP_ARRAY
            for b in $BACKUPS; do
                BACKUP_DATE=$(basename "$b" | sed 's/flows.json.backup.//')
                FORMATTED_DATE=$(echo "$BACKUP_DATE" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
                BACKUP_SIZE=$(du -h "$b" | cut -f1)
                echo "  $i) $FORMATTED_DATE ($BACKUP_SIZE)"
                BACKUP_ARRAY[$i]="$b"
                i=$((i+1))
                # Mostrar máximo 10
                if [ $i -gt 10 ]; then
                    break
                fi
            done
            
            echo ""
            read -p "  Selecciona backup [1-$((i-1))]: " BACKUP_CHOICE
            
            SELECTED_BACKUP="${BACKUP_ARRAY[$BACKUP_CHOICE]}"
            
            if [ -z "$SELECTED_BACKUP" ] || [ ! -f "$SELECTED_BACKUP" ]; then
                echo "  ❌ Opción no válida"
                exit 1
            fi
            
            echo ""
            echo "  📥 Restaurando backup..."
            
            # Detectar si el backup necesita FlowFuse o Clásico
            # FlowFuse usa nodos tipo "ui-button", "ui-chart" (con guión)
            # Clásico usa nodos tipo "ui_button", "ui_chart" (con guión bajo)
            NEEDS_FLOWFUSE="no"
            if grep -q '"type":\s*"ui-' "$SELECTED_BACKUP" 2>/dev/null; then
                NEEDS_FLOWFUSE="yes"
            fi
            
            # Verificar dashboards instalados
            NODERED_MODULES="$NODERED_DIR/node_modules"
            HAS_FLOWFUSE=$([ -d "$NODERED_MODULES/@flowfuse/node-red-dashboard" ] && echo "yes" || echo "no")
            HAS_CLASSIC=$([ -d "$NODERED_MODULES/node-red-dashboard" ] && echo "yes" || echo "no")
            
            # Resolver conflictos de dashboard
            cd "$NODERED_DIR"
            if [ "$NEEDS_FLOWFUSE" = "yes" ]; then
                if [ "$HAS_FLOWFUSE" = "no" ]; then
                    echo "  ⚠️  Este backup requiere FlowFuse Dashboard"
                    echo "  Instalando..."
                    npm uninstall node-red-dashboard 2>/dev/null || true
                    npm install @flowfuse/node-red-dashboard --save
                    echo "  ✅ FlowFuse Dashboard instalado"
                elif [ "$HAS_CLASSIC" = "yes" ]; then
                    echo "  ⚠️  Limpiando conflicto de dashboards..."
                    npm uninstall node-red-dashboard 2>/dev/null || true
                    echo "  ✅ Conflicto resuelto"
                fi
            else
                if [ "$HAS_CLASSIC" = "no" ]; then
                    echo "  ⚠️  Este backup requiere Dashboard Clásico"
                    echo "  Instalando..."
                    npm uninstall @flowfuse/node-red-dashboard 2>/dev/null || true
                    npm install node-red-dashboard --save
                    echo "  ✅ Dashboard Clásico instalado"
                elif [ "$HAS_FLOWFUSE" = "yes" ]; then
                    echo "  ⚠️  Limpiando conflicto de dashboards..."
                    npm uninstall @flowfuse/node-red-dashboard 2>/dev/null || true
                    echo "  ✅ Conflicto resuelto"
                fi
            fi
            
            # Guardar configuración MQTT actual antes de restaurar
            MQTT_CONFIG=$(python3 -c "
import json
try:
    with open('$NODERED_DIR/flows.json', 'r') as f:
        flows = json.load(f)
    for node in flows:
        if node.get('type') == 'mqtt-broker':
            print(json.dumps({
                'broker': node.get('broker', 'localhost'),
                'port': node.get('port', '1883'),
                'usetls': node.get('usetls', False)
            }))
            break
except:
    pass
" 2>/dev/null)
            
            # Hacer backup del actual antes de restaurar
            cp "$NODERED_DIR/flows.json" "$NODERED_DIR/flows.json.backup.$(date +%Y%m%d%H%M%S)"
            
            # Restaurar
            cp "$SELECTED_BACKUP" "$NODERED_DIR/flows.json"
            
            # Restaurar configuración MQTT si existía
            if [ -n "$MQTT_CONFIG" ]; then
                python3 -c "
import json
mqtt_config = json.loads('$MQTT_CONFIG')
with open('$NODERED_DIR/flows.json', 'r') as f:
    flows = json.load(f)
for node in flows:
    if node.get('type') == 'mqtt-broker':
        node['broker'] = mqtt_config['broker']
        node['port'] = mqtt_config['port']
        node['usetls'] = mqtt_config['usetls']
with open('$NODERED_DIR/flows.json', 'w') as f:
    json.dump(flows, f, indent=4)
" 2>/dev/null
                echo "  ✅ Flow restaurado"
                echo "  🔗 Configuración MQTT preservada: ${MQTT_CONFIG}"
            else
                echo "  ✅ Flow restaurado"
            fi
            echo ""
            echo "  🔄 Reiniciando Node-RED..."
            sudo systemctl restart nodered
            sleep 5
            echo "  ✅ Node-RED reiniciado"
            
            # Reiniciar kiosko si existe
            if systemctl is-active --quiet kiosk.service 2>/dev/null; then
                echo ""
                echo "  🔄 Reiniciando modo kiosko..."
                sudo systemctl restart kiosk.service
                sleep 2
                echo "  ✅ Kiosko reiniciado"
            fi
            
            exit 0
            ;;
        7)
            echo ""
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Modificar configuración equipo"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
            # Buscar equipo_config.json
            CONFIG_FILE=""
            for f in /home/*/config/equipo_config.json; do
                if [ -f "$f" ]; then
                    CONFIG_FILE="$f"
                    break
                fi
            done
            
            if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
                echo "  ❌ No se encontró equipo_config.json"
                echo "  Crea el archivo en: /home/gesinne/config/equipo_config.json"
                exit 1
            fi
            
            # Leer valores actuales
            CURRENT_SERIE=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('serie', 'N/A'))" 2>/dev/null)
            CURRENT_POTENCIA=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('potencia', 'N/A'))" 2>/dev/null)
            CURRENT_IMAX=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('Imax', 'N/A'))" 2>/dev/null)
            CURRENT_T1=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('tramo1', 'N/A'))" 2>/dev/null)
            CURRENT_T2=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('tramo2', 'N/A'))" 2>/dev/null)
            CURRENT_T3=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('tramo3', 'N/A'))" 2>/dev/null)
            CURRENT_T4=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('tramo4', 'N/A'))" 2>/dev/null)
            
            echo "  Configuración actual:"
            echo ""
            echo "  Serie:    $CURRENT_SERIE"
            echo "  Potencia: $CURRENT_POTENCIA"
            echo "  Imax:     $CURRENT_IMAX"
            echo "  Tramo 1:  $CURRENT_T1"
            echo "  Tramo 2:  $CURRENT_T2"
            echo "  Tramo 3:  $CURRENT_T3"
            echo "  Tramo 4:  $CURRENT_T4"
            echo ""
            
            read -p "  ¿Modificar? [s/N]: " MODIFY
            if [ "$MODIFY" = "s" ] || [ "$MODIFY" = "S" ]; then
                echo ""
                read -p "  Serie [$CURRENT_SERIE]: " NEW_SERIE
                read -p "  Potencia [$CURRENT_POTENCIA]: " NEW_POTENCIA
                read -p "  Imax [$CURRENT_IMAX]: " NEW_IMAX
                read -p "  Tramo 1 [$CURRENT_T1]: " NEW_T1
                read -p "  Tramo 2 [$CURRENT_T2]: " NEW_T2
                read -p "  Tramo 3 [$CURRENT_T3]: " NEW_T3
                read -p "  Tramo 4 [$CURRENT_T4]: " NEW_T4
                
                # Usar valores actuales si no se introducen nuevos
                NEW_SERIE="${NEW_SERIE:-$CURRENT_SERIE}"
                NEW_POTENCIA="${NEW_POTENCIA:-$CURRENT_POTENCIA}"
                NEW_IMAX="${NEW_IMAX:-$CURRENT_IMAX}"
                NEW_T1="${NEW_T1:-$CURRENT_T1}"
                NEW_T2="${NEW_T2:-$CURRENT_T2}"
                NEW_T3="${NEW_T3:-$CURRENT_T3}"
                NEW_T4="${NEW_T4:-$CURRENT_T4}"
                
                # Guardar nueva configuración
                python3 -c "
import json
with open('$CONFIG_FILE') as f:
    data = json.load(f)
data['serie'] = '$NEW_SERIE'
data['potencia'] = int('$NEW_POTENCIA')
data['Imax'] = int('$NEW_IMAX')
data['tramo1'] = int('$NEW_T1')
data['tramo2'] = int('$NEW_T2')
data['tramo3'] = int('$NEW_T3')
data['tramo4'] = int('$NEW_T4')
with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=4)
" 2>/dev/null
                
                echo ""
                echo "  ✅ Configuración guardada"
                echo ""
                echo "  🔄 Reiniciando Node-RED para aplicar cambios..."
                sudo systemctl restart nodered
                sleep 2
                echo "  ✅ Node-RED reiniciado"
                
                # Reiniciar kiosko si existe
                if systemctl is-active --quiet kiosk.service 2>/dev/null; then
                    echo ""
                    echo "  🔄 Reiniciando modo kiosko..."
                    sudo systemctl restart kiosk.service
                    sleep 2
                    echo "  ✅ Kiosko reiniciado"
                fi
            fi
            
            exit 0
            ;;
        8)
            echo ""
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Leer registros Modbus"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  ¿Qué tarjeta quieres leer?"
            echo ""
            echo "  1) Tarjeta L1 (Fase 1)"
            echo "  2) Tarjeta L2 (Fase 2)"
            echo "  3) Tarjeta L3 (Fase 3)"
            echo ""
            read -p "  Opción [1-3]: " TARJETA
            
            case $TARJETA in
                1) UNIT_ID=1; FASE="L1" ;;
                2) UNIT_ID=2; FASE="L2" ;;
                3) UNIT_ID=3; FASE="L3" ;;
                *) echo "  ❌ Opción no válida"; exit 1 ;;
            esac
            
            # Siempre detectar el máximo de registros
            NUM_REGS=200
            DETECT_MAX="yes"
            
            echo ""
            echo "  ⚠️  Se parará Node-RED temporalmente para leer..."
            echo ""
            
            sudo systemctl stop nodered
            sleep 1
            
            echo "  📡 Leyendo $NUM_REGS registros de Tarjeta $FASE (Unit ID: $UNIT_ID)..."
            echo ""
            
            python3 << EOF
import sys
try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    try:
        from pymodbus.client.sync import ModbusSerialClient
    except ImportError:
        print("  ❌ pymodbus no instalado. Instala con: pip3 install pymodbus")
        sys.exit(1)

client = ModbusSerialClient(
    port='/dev/ttyAMA0',
    baudrate=115200,
    bytesize=8,
    parity='N',
    stopbits=1,
    timeout=1
)

if not client.connect():
    print("  ❌ No se pudo conectar al puerto serie /dev/ttyAMA0")
    sys.exit(1)

try:
    num_regs = $NUM_REGS
    detect_max = "$DETECT_MAX" == "yes"
    
    if detect_max:
        print("  🔍 Detectando número máximo de registros...")
        print("")
        # Probar de 10 en 10 hasta encontrar el límite
        max_reg = 0
        for test_count in range(10, 201, 10):
            result = client.read_holding_registers(address=0, count=test_count, slave=$UNIT_ID)
            if result.isError():
                # Afinar buscando de 1 en 1
                for fine_count in range(max_reg + 1, test_count):
                    result = client.read_holding_registers(address=0, count=fine_count, slave=$UNIT_ID)
                    if result.isError():
                        break
                    max_reg = fine_count
                break
            max_reg = test_count
        
        print(f"  ✅ Máximo detectado: {max_reg} registros")
        print("")
        num_regs = max_reg
    
    # Leer los registros
    data = []
    # Leer en bloques de 40 para mayor compatibilidad
    for start in range(0, num_regs, 40):
        count = min(40, num_regs - start)
        result = client.read_holding_registers(address=start, count=count, slave=$UNIT_ID)
        if result.isError():
            print(f"  ⚠️  Error en registros {start}-{start+count-1}")
            break
        data.extend(result.registers)
    
    if data:
        print(f"  📋 Registros Tarjeta $FASE (0-{len(data)-1}):")
        print("")
        print("  " + ",".join(str(val) for val in data))
        print("")
        print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  DATOS EN TIEMPO REAL")
        print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print(f"   0  Estado chopper:        {data[0]}")
        print(f"   1  Topología actual:      {data[1]}")
        print(f"   2  Alarma:                {data[2]}")
        print(f"   3  Tensión salida:        {data[3]/100:.2f} V")
        print(f"   4  Tensión entrada:       {data[4]/100:.2f} V")
        print(f"   5  Frecuencia:            {data[5]/100:.2f} Hz")
        print(f"   6  Corriente salida:      {data[6]/10:.1f} A")
        print(f"   7  Corriente chopper:     {data[7]/100:.2f} A")
        print(f"   8  Corriente primario:    {data[8]/100:.2f} A")
        pot_activa = ((data[9] << 16) | data[10]) / 10000
        pot_reactiva = ((data[11] << 16) | data[12]) / 10000
        pot_aparente = ((data[13] << 16) | data[14]) / 10000
        print(f"  9-10 Potencia activa:      {pot_activa:.2f} kW")
        print(f" 11-12 Potencia reactiva:    {pot_reactiva:.2f} kVAr")
        print(f" 13-14 Potencia aparente:    {pot_aparente:.2f} kVA")
        print(f"  15  Factor potencia:       {data[15]/100:.2f}")
        print(f"  16  Tipo FP:               {data[16]}")
        print(f"  17  Temperatura:           {data[17]/10:.1f} °C")
        print(f"  18  Temp admisible:        {data[18]/10:.1f} °C")
        print(f"  19  Enable regulación ext: {data[19]}")
        print(f"  20  Tiempo reencendido:    {data[20]} s")
        print(f"  21  Enable reg. switch:    {data[21]}")
        print("")
        print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  REGISTROS DE ESTADO (30-34)")
        print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print(f"  30  Flag escritura estado: {data[30]}")
        print(f"  31  Estado deseado:        {data[31]}  (0=normal, 1=bypass, 2=reg)")
        print(f"  32  Consigna deseada:      {data[32]/10:.1f} V")
        print(f"  33  Bucle control:         {data[33]}")
        print(f"  34  Mando control:         {data[34]}")
        print("")
        print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  CONFIGURACIÓN (40-69)")
        print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print(f"  40  Flag escritura config: {data[40]}")
        print(f"  41  Número de serie:       {data[41]}")
        print(f"  42  Tensión nominal:       {data[42]/10:.1f} V")
        print(f"  43  V primario autotrafo:  {data[43]/10:.1f} V")
        print(f"  44  V primario trafo:      {data[44]/10:.1f} V")
        print(f"  45  V secundario trafo:    {data[45]/10:.1f} V")
        print(f"  46  Topología:             {data[46]}  (0-4)")
        print(f"  47  Dead-time:             {data[47]}")
        print(f"  48  Dirección MODBUS:      {data[48]}")
        print(f"  49  I nominal salida:      {data[49]}")
        print(f"  50  I nominal chopper:     {data[50]}")
        print(f"  51  I max chopper (eficaz):{data[51]}")
        print(f"  52  I max chopper (pico):  {data[52]}")
        print(f"  53  Tiempo apagado CC/TT:  {data[53]}")
        print(f"  54  Nº apagados sobrecorr: {data[54]}")
        print(f"  55  Estado inicial:        {data[55]}  (0 o 2)")
        print(f"  56  Consigna inicial:      {data[56]/10:.1f} V")
        print(f"  57  Temp máxima:           {data[57]/10:.1f} °C")
        print(f"  58  Decremento temp:       {data[58]/10:.1f} °C")
        print(f"  59  Nº apagados sobretemp: {data[59]}")
        print(f"  60  Tipo alimentación:     {data[60]}  (0 o 1)")
        print(f"  61  Velocidad MODBUS:      {data[61]}  (0-2)")
        print(f"  62  Empaquetado transis:   {data[62]}  (0 o 1)")
        print(f"  63  Ángulo cargas altas:   {data[63]}")
        print(f"  64  Ángulo cargas bajas:   {data[64]}")
        print(f"  65  % I max carga baja:    {data[65]}")
        print(f"  66  Sensib. transitorios:  {data[66]}  (0-4)")
        if len(data) > 67:
            print(f"  67  Sensib. derivada I:    {data[67]}")
            print(f"  69  Reset config defecto:  {data[69] if len(data) > 69 else 'N/A'}")
        print("")
        if len(data) > 70:
            print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("  CALIBRACIÓN (70-86)")
            print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print(f"  70  Flag escritura calib: {data[70]}")
            print(f"  71  K tensión salida:     {data[71]}")
            print(f"  72  K tensión entrada:    {data[72]}")
            print(f"  73  b tensión salida:     {data[73]}")
            print(f"  74  b tensión entrada:    {data[74]}")
            print(f"  75  K corriente chopper:  {data[75]}")
            print(f"  76  K corriente equipo:   {data[76]}")
            print(f"  77  b corriente chopper:  {data[77]}")
            print(f"  78  b corriente equipo:   {data[78]}")
            print(f"  79  Ruido I chopper:      {data[79]}")
            print(f"  80  Ruido I equipo:       {data[80]}")
            print(f"  81  K potencia salida:    {data[81]}")
            print(f"  82  b potencia salida:    {data[82]}")
            print(f"  83  Desfase V-I:          {data[83]}")
            print(f"  84  Calib frecuencia:     {data[84]}")
            print(f"  85  Calib ruido I:        {data[85]}")
            print(f"  86  Reset calib defecto:  {data[86]}")
        if len(data) > 90:
            print("")
            print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("  CONTROL (90-95)")
            print("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print(f"  90  Flag escritura ctrl:  {data[90]}")
            print(f"  91  Parámetro A control:  {data[91]}")
            print(f"  92  Parámetro B control:  {data[92]}")
            print(f"  93  Escalón max (EMM):    {data[93]}")
            print(f"  94  Escalón max V0:       {data[94]}")
            print(f"  95  Escalón max V1:       {data[95]}")
        print("")
    else:
        print("  ❌ No se pudieron leer registros")
    
except Exception as e:
    print(f"  ❌ Error: {e}")
finally:
    client.close()
EOF
            
            echo "  🔄 Reiniciando Node-RED..."
            sudo systemctl start nodered
            sleep 2
            
            # Reiniciar kiosko si existe
            if systemctl is-active --quiet kiosk.service 2>/dev/null; then
                sudo systemctl restart kiosk.service
            fi
            
            echo "  ✅ Listo"
            
            exit 0
            ;;
        *)
            echo ""
            echo "  👋 Saliendo"
            exit 0
            ;;
    esac
else
    # Primera instalación - preguntar modo
    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  PASO 1: Modo de conexión"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  ¿Cómo quieres enviar los datos?"
    echo ""
    echo "  1) Azure IoT Hub (localhost → Azure → Servidor)"
    echo "     Node-RED envía a localhost, el bridge reenvía a Azure"
    echo ""
    echo "  2) Servidor directo (Node-RED → mqtt.gesinne.cloud)"
    echo "     Node-RED envía directamente al servidor (modo tradicional)"
    echo ""
    read -p "  Opción [1/2]: " CONNECTION_MODE
fi

# Solo pedir connection string si elige Azure
if [ "$CONNECTION_MODE" = "1" ]; then
    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  PASO 2: Connection String"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Pega la Connection String del dispositivo Azure"
    echo "  (te la proporciona Gesinne o el cliente)"
    echo ""
    read -p "  Connection String: " AZURE_CONNECTION_STRING

    if [ -z "$AZURE_CONNECTION_STRING" ]; then
        echo ""
        echo "  ❌ No has introducido nada. Abortando."
        exit 1
    fi

    # Validar formato básico
    if [[ ! "$AZURE_CONNECTION_STRING" =~ HostName=.*DeviceId=.*SharedAccessKey= ]]; then
        echo ""
        echo "  ❌ Formato incorrecto. Debe contener:"
        echo "     HostName=xxx;DeviceId=xxx;SharedAccessKey=xxx"
        exit 1
    fi

    echo ""
    echo "  ✅ Connection String válida"
fi

# Buscar archivo de flows de Node-RED
USER_HOME="/home/$(logname 2>/dev/null || echo 'pi')"
FLOWS_FILE=""
for f in "$USER_HOME/.node-red/flows.json" "/home/pi/.node-red/flows.json" "/home/gesinne/.node-red/flows.json"; do
    if [ -f "$f" ]; then
        FLOWS_FILE="$f"
        break
    fi
done

if [ -z "$FLOWS_FILE" ]; then
    echo ""
    echo "  ⚠️  Node-RED no detectado (no se encontró flows.json)"
    echo "     Configura manualmente el broker MQTT"
else
    # Obtener configuración actual
    BROKER_HOST=$(python3 -c "
import json
try:
    with open('$FLOWS_FILE', 'r') as f:
        flows = json.load(f)
    for node in flows:
        if node.get('type') == 'mqtt-broker':
            print(node.get('broker', 'no configurado'))
            break
except:
    print('error')
" 2>/dev/null)

    echo ""
    echo "  📡 Node-RED detectado"
    echo "  📁 Archivo: $FLOWS_FILE"
    echo "  🔗 Broker actual: $BROKER_HOST"
    echo ""

    # Hacer backup antes de cualquier cambio
    cp "$FLOWS_FILE" "${FLOWS_FILE}.backup.$(date +%Y%m%d%H%M%S)"

    if [ "$CONNECTION_MODE" = "1" ]; then
        # Modo Azure IoT - cambiar a localhost
        if [ "$BROKER_HOST" != "localhost" ] && [ "$BROKER_HOST" != "127.0.0.1" ]; then
            python3 -c "
import json
with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)
for node in flows:
    if node.get('type') == 'mqtt-broker':
        node['broker'] = 'localhost'
        node['port'] = '1883'
        node['usetls'] = False
with open('$FLOWS_FILE', 'w') as f:
    json.dump(flows, f, indent=4)
" 2>/dev/null
            echo "  ✅ Broker cambiado a localhost:1883 (sin SSL)"
            RESTART_NODERED=1
        else
            echo "  ✅ Broker ya configurado en localhost"
        fi
        USE_AZURE=1
    else
        # Modo servidor directo
        echo ""
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Configuración servidor MQTT remoto"
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        read -p "  Servidor MQTT [mqtt.gesinne.cloud]: " MQTT_SERVER
        MQTT_SERVER=${MQTT_SERVER:-mqtt.gesinne.cloud}
        
        read -p "  Puerto [8883]: " MQTT_PORT
        MQTT_PORT=${MQTT_PORT:-8883}
        
        read -p "  Usar SSL (s/n) [s]: " MQTT_SSL
        MQTT_SSL=${MQTT_SSL:-s}
        if [ "$MQTT_SSL" = "s" ] || [ "$MQTT_SSL" = "S" ]; then
            USE_TLS="True"
        else
            USE_TLS="False"
        fi
        
        read -p "  Usuario MQTT: " MQTT_USER
        read -s -p "  Contraseña MQTT: " MQTT_PASS
        echo ""
        
        if [ -z "$MQTT_USER" ] || [ -z "$MQTT_PASS" ]; then
            echo ""
            echo "  ❌ Usuario y contraseña son obligatorios"
            exit 1
        fi
        
        python3 -c "
import json
with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)
for node in flows:
    if node.get('type') == 'mqtt-broker':
        node['broker'] = '$MQTT_SERVER'
        node['port'] = '$MQTT_PORT'
        node['usetls'] = $USE_TLS
with open('$FLOWS_FILE', 'w') as f:
    json.dump(flows, f, indent=4)
" 2>/dev/null

        # Guardar credenciales en flows_cred.json
        CRED_FILE="${FLOWS_FILE%flows.json}flows_cred.json"
        BROKER_ID=$(python3 -c "
import json
with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)
for node in flows:
    if node.get('type') == 'mqtt-broker':
        print(node.get('id', ''))
        break
" 2>/dev/null)

        if [ -n "$BROKER_ID" ]; then
            python3 -c "
import json
import os
cred_file = '$CRED_FILE'
creds = {}
if os.path.exists(cred_file):
    with open(cred_file, 'r') as f:
        creds = json.load(f)
creds['$BROKER_ID'] = {'user': '$MQTT_USER', 'password': '$MQTT_PASS'}
with open(cred_file, 'w') as f:
    json.dump(creds, f, indent=4)
" 2>/dev/null
            chmod 600 "$CRED_FILE"
        fi

        echo ""
        echo "  ✅ Broker: $MQTT_SERVER:$MQTT_PORT (SSL: $MQTT_SSL)"
        echo "  ✅ Usuario: $MQTT_USER"
        echo "  ✅ Credenciales guardadas"
        RESTART_NODERED=1
        USE_AZURE=0
    fi

    # Reiniciar Node-RED si hubo cambios
    if [ "$RESTART_NODERED" = "1" ]; then
        echo ""
        echo "  ⚠️  Reiniciando Node-RED..."
        systemctl restart nodered 2>/dev/null || node-red-restart 2>/dev/null || true
        sleep 2
        echo "  ✅ Node-RED reiniciado"
    fi
fi

# Si eligió modo servidor directo, no necesita el bridge de Azure
if [ "$CONNECTION_MODE" = "2" ]; then
    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║                                              ║"
    echo "  ║   ✅ CONFIGURACIÓN COMPLETADA                ║"
    echo "  ║                                              ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo ""
    echo "  Node-RED enviará directamente al servidor."
    echo "  No se necesita el bridge de Azure IoT."
    echo ""
    exit 0
fi

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PASO 3: Instalando Docker"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Instalar Docker si no existe
if ! command -v docker &> /dev/null; then
    echo "  Instalando Docker (puede tardar unos minutos)..."
    apt-get update -qq
    apt-get install -y -qq docker.io docker-compose > /dev/null 2>&1
    systemctl start docker
    systemctl enable docker
    echo "  ✅ Docker instalado"
else
    echo "  ✅ Docker ya instalado"
fi

# Instalar docker-compose si no existe
if ! command -v docker-compose &> /dev/null; then
    apt-get install -y -qq docker-compose > /dev/null 2>&1
    echo "  ✅ Docker Compose instalado"
fi

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PASO 4: Descargando software"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -d "$INSTALL_DIR/.git" ]; then
    cd "$INSTALL_DIR"
    git stash -q 2>/dev/null || true
    git fetch -q origin main
    git reset --hard origin/main -q
    echo "  ✅ Software actualizado"
elif [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    git clone -q https://github.com/Gesinne/rpi-azure-bridge.git "$INSTALL_DIR"
    echo "  ✅ Software descargado"
else
    git clone -q https://github.com/Gesinne/rpi-azure-bridge.git "$INSTALL_DIR"
    echo "  ✅ Software descargado"
fi

cd "$INSTALL_DIR"

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PASO 5: Configurando e iniciando"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Crear docker-compose.override.yml con la connection string
cat > docker-compose.override.yml << EOF
services:
  mqtt-to-azure:
    environment:
      - AZURE_CONNECTION_STRING=${AZURE_CONNECTION_STRING}
EOF

chmod 600 docker-compose.override.yml

# Parar contenedor anterior si existe
docker-compose down 2>/dev/null || true

# Construir e iniciar
echo "  Iniciando servicio (puede tardar 1-2 minutos)..."
if docker-compose up -d --build 2>&1 | tail -5; then
    sleep 3
    if docker-compose ps | grep -q "Up"; then
        echo "  ✅ Servicio iniciado"
    else
        echo "  ❌ Error: El contenedor no arrancó"
        echo ""
        docker-compose logs --tail=20
        exit 1
    fi
else
    echo "  ❌ Error al construir el contenedor"
    exit 1
fi

echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║                                              ║"
echo "  ║   ✅ INSTALACIÓN COMPLETADA                  ║"
echo "  ║                                              ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""
echo "  El servicio está funcionando y se iniciará"
echo "  automáticamente cuando reinicies la Raspberry."
echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Verificando conexión..."
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

sleep 5
docker-compose logs --tail=15 2>/dev/null | grep -E "✅|❌|📤|⚠️" | head -10

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
# Wed Dec  3 17:09:10 UTC 2025
# force 1764842449
