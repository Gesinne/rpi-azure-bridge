#!/bin/bash
#
# Instalador automático GESINNE INGENIERÍA
# 
# COMANDO ÚNICO PARA INSTALAR O ACTUALIZAR:
# curl -sL https://gesinne.es/rpi | bash
# o
# wget -qO- https://raw.githubusercontent.com/Gesinne/rpi-azure-bridge/main/install.sh > /tmp/g.sh && bash /tmp/g.sh
#
# Una vez instalado, ejecutar con: gesinne
#

# Si se ejecuta desde curl/pipe, descargar y ejecutar localmente
if [ ! -t 0 ]; then
    SCRIPT_URL="https://raw.githubusercontent.com/Gesinne/rpi-azure-bridge/main/install.sh"
    TEMP_SCRIPT="/tmp/gesinne_install_$$.sh"
    curl -sL "$SCRIPT_URL" -o "$TEMP_SCRIPT" 2>/dev/null || wget -qO "$TEMP_SCRIPT" "$SCRIPT_URL"
    chmod +x "$TEMP_SCRIPT"
    exec sudo bash "$TEMP_SCRIPT" "$@"
    exit 0
fi

# Instalar comando 'Actualizar' si no existe
if [ ! -f /usr/local/bin/Actualizar ]; then
    cat > /usr/local/bin/Actualizar << 'EOFCMD'
#!/bin/bash
# Comando Actualizar - Lanza el instalador/configurador de Gesinne
SCRIPT_URL="https://raw.githubusercontent.com/Gesinne/rpi-azure-bridge/main/install.sh"
TEMP_SCRIPT="/tmp/gesinne_install_$$.sh"
curl -sL "$SCRIPT_URL" -o "$TEMP_SCRIPT" 2>/dev/null || wget -qO "$TEMP_SCRIPT" "$SCRIPT_URL"
chmod +x "$TEMP_SCRIPT"
exec sudo bash "$TEMP_SCRIPT" "$@"
EOFCMD
    chmod +x /usr/local/bin/Actualizar
    echo "  ✅ Comando 'Actualizar' instalado"
fi

# Auto-detectar si necesita clonar o actualizar el repo
USER_HOME="/home/$(logname 2>/dev/null || echo ${SUDO_USER:-$USER})"
INSTALL_DIR="$USER_HOME/rpi-azure-bridge"

# Si no se ha actualizado aún (argumento --updated), actualizar y re-ejecutar desde el repo
if [ "$1" != "--updated" ]; then
    echo ""
    echo "  🔄 Obteniendo última versión..."
    
    # Borrar y clonar siempre
    rm -rf "$INSTALL_DIR" 2>/dev/null || true
    git clone https://github.com/Gesinne/rpi-azure-bridge.git "$INSTALL_DIR"
    
    # Ejecutar el script del repo con marca de actualizado
    exec bash "$INSTALL_DIR/install.sh" --updated
fi

set -e
cd "$INSTALL_DIR"

clear
echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║                                              ║"
echo "  ║         GESINNE INGENIERÍA                   ║"
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

# Función para preguntar si volver al menú o salir
volver_menu() {
    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -p "  Pulsa ENTER para volver al menú (0 para salir): " VOLVER
    if [ "$VOLVER" = "0" ]; then
        echo ""
        echo "  👋 ¡Hasta luego!"
        echo ""
        exit 0
    fi
}

# Verificar y reparar Logo + httpStatic si falta
for NODERED_DIR in /home/*/.node-red; do
    if [ -d "$NODERED_DIR" ]; then
        USER_HOME_DIR=$(dirname "$NODERED_DIR")
        SETTINGS_FILE="$NODERED_DIR/settings.js"
        
        # Si no existe carpeta Logo, intentar descargarla del repo
        if [ ! -d "$USER_HOME_DIR/Logo" ]; then
            echo "  ⚠️  Falta carpeta Logo, descargando..."
            TEMP_LOGO="/tmp/logo_download_$$"
            if git clone --depth 1 --filter=blob:none --sparse https://github.com/Gesinne/nodered-flows.git "$TEMP_LOGO" 2>/dev/null; then
                cd "$TEMP_LOGO"
                git sparse-checkout set Logo 2>/dev/null
                if [ -d "$TEMP_LOGO/Logo" ]; then
                    cp -r "$TEMP_LOGO/Logo" "$USER_HOME_DIR/"
                    chown -R $(basename "$USER_HOME_DIR"):$(basename "$USER_HOME_DIR") "$USER_HOME_DIR/Logo" 2>/dev/null
                    echo "  ✅ Carpeta Logo instalada en $USER_HOME_DIR/Logo"
                fi
                cd - > /dev/null
                rm -rf "$TEMP_LOGO"
            fi
        fi
        
        # Si existe Logo pero no está configurado httpStatic
        if [ -d "$USER_HOME_DIR/Logo" ] && [ -f "$SETTINGS_FILE" ]; then
            if ! grep -q "httpStatic:" "$SETTINGS_FILE"; then
                sed -i "/module.exports\s*=\s*{/a\\    httpStatic: '$USER_HOME_DIR/Logo/'," "$SETTINGS_FILE"
                echo "  ✅ httpStatic configurado en settings.js"
                sudo systemctl restart nodered 2>/dev/null
            fi
        fi
        break
    fi
done

# Bucle del menú principal
while true; do
    clear
    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔧 Gesinne RPI Azure Bridge - Instalador"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Mostrar estado
    if [ -f "$OVERRIDE_FILE" ]; then
        echo "  ✅ Bridge Azure IoT instalado"
    else
        echo "  ⚠️  Bridge no configurado"
    fi
    show_nodered_config

    # Mostrar URL del kiosko si existe
    KIOSK_SCRIPT="/home/$(logname 2>/dev/null || echo ${SUDO_USER:-gesinne})/kiosk.sh"
    if [ -f "$KIOSK_SCRIPT" ]; then
        KIOSK_URL=$(grep -oP 'http://[^ ]+' "$KIOSK_SCRIPT" 2>/dev/null | head -1)
        if [ -n "$KIOSK_URL" ]; then
            if echo "$KIOSK_URL" | grep -q "/dashboard"; then
                echo "  🖥️  Kiosko: $KIOSK_URL (FlowFuse)"
            elif echo "$KIOSK_URL" | grep -q "/ui"; then
                echo "  🖥️  Kiosko: $KIOSK_URL (Clásico)"
            else
                echo "  🖥️  Kiosko: $KIOSK_URL"
            fi
        fi
    fi
    echo ""
    echo "  ¿Qué deseas hacer?"
    echo ""
    echo "  1) Modo de conexión (Azure IoT / Servidor Remoto)"
    echo "  2) Actualizar Flow Node-RED"
    echo "  3) Restaurar Flow anterior (backup)"
    echo "  4) Ver/Modificar configuración equipo"
    echo "  5) Ver los 96 registros de la placa"
    echo "  6) Descargar parámetros (enviar por EMAIL)"
    echo "  7) Revisar espacio y logs"
    echo "  8) Gestionar paleta Node-RED"
    echo "  0) Salir"
    echo ""
    read -p "  Opción [0-8]: " OPTION

    case $OPTION in
        0)
            echo ""
            echo "  👋 ¡Hasta luego!"
            echo ""
            exit 0
            ;;
    1)
            # Modo de conexión - ir al menú de selección
            echo ""
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Modo de conexión"
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
            echo "  0) Volver al menú"
            echo ""
            read -p "  Opción [0/1/2]: " MODE_CHOICE
            case $MODE_CHOICE in
                0) continue ;;
                1) CONNECTION_MODE="1" ;;
                2) CONNECTION_MODE="2" ;;
                *) echo "  ❌ Opción no válida"; continue ;;
            esac
            
            # La configuración de Azure se ejecuta después del case
            # Salir del bucle para ejecutar el código de Azure
            break
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
            
            # Mostrar maxQueue del nodo guaranteed-delivery desde flows.json
            for flowfile in /home/*/.node-red/flows.json; do
                if [ -f "$flowfile" ]; then
                    python3 -c "
import json
try:
    # Leer RAM
    with open('/proc/meminfo') as f:
        for line in f:
            if line.startswith('MemTotal:'):
                mem_kb = int(line.split()[1])
                mem_gb = mem_kb / 1024 / 1024
                break
    
    # Calcular recomendado según RAM
    if mem_gb < 2.5:
        recommended = 500000
    elif mem_gb < 5.5:
        recommended = 1000000
    else:
        recommended = 2000000
    
    with open('$flowfile') as f:
        flows = json.load(f)
    for node in flows:
        if node.get('type') == 'guaranteed-delivery':
            maxq = node.get('maxQueue', '?')
            print(f'  📨 Cola máxima: {maxq} (RAM: {mem_gb:.1f} GB → recomendado: {recommended})')
            break
except:
    pass
" 2>/dev/null
                    break
                fi
            done
            
            # Mostrar maxSizeMB configurado en flows.json y RAM
            for flowfile in /home/*/.node-red/flows.json; do
                if [ -f "$flowfile" ]; then
                    python3 -c "
import re
try:
    # Leer RAM
    with open('/proc/meminfo') as f:
        for line in f:
            if line.startswith('MemTotal:'):
                mem_kb = int(line.split()[1])
                mem_gb = mem_kb / 1024 / 1024
                break
    
    # Leer maxSizeMB del flows.json (buscar todos los valores)
    with open('$flowfile') as f:
        content = f.read()
    
    # Buscar el valor por defecto (|| 200)
    match = re.search(r\"flow\.get\('maxSizeMB'\)\s*\|\|\s*(\d+)\", content)
    if match:
        configured = match.group(1)
    else:
        # Buscar asignaciones directas
        matches = re.findall(r'maxSizeMB\s*=\s*(\d+)', content)
        configured = matches[0] if matches else '?'
    
    # Calcular recomendado según RAM
    if mem_gb < 2.5:
        recommended = 200
    elif mem_gb < 5.5:
        recommended = 400
    else:
        recommended = 800
    
    print(f'  � Max cola SD: {configured} MB (RAM: {mem_gb:.1f} GB → recomendado: {recommended} MB)')
except Exception as e:
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
            
            # Mostrar versiones de Node-RED y RPI Connect
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Versiones instaladas"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
            # Versión Node-RED (solo primera línea con versión)
            NODERED_VERSION=$(node-red --version 2>/dev/null | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "No instalado")
            NODERED_LATEST=$(curl -s https://registry.npmjs.org/node-red/latest 2>/dev/null | grep -oE '"version":"[0-9]+\.[0-9]+\.[0-9]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "?")
            if [ "$NODERED_VERSION" = "v$NODERED_LATEST" ]; then
                echo "  🔴 Node-RED: $NODERED_VERSION ✅"
            elif [ "$NODERED_LATEST" != "?" ]; then
                echo "  🔴 Node-RED: $NODERED_VERSION → v$NODERED_LATEST disponible ⬆️"
            else
                echo "  🔴 Node-RED: $NODERED_VERSION"
            fi
            
            # Versión Node.js
            NODE_VERSION=$(node --version 2>/dev/null || echo "No instalado")
            # Solo mostrar versión instalada, sin complicar con LTS
            echo "  🟢 Node.js: $NODE_VERSION ✅"
            
            # Versión RPI Connect
            if command -v rpi-connect &> /dev/null; then
                RPICONNECT_VERSION=$(rpi-connect --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")
                RPICONNECT_STATUS=$(systemctl is-active rpi-connect 2>/dev/null || echo "inactivo")
                # Comprobar última versión disponible
                RPICONNECT_LATEST=$(apt-cache policy rpi-connect 2>/dev/null | grep Candidate | awk '{print $2}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "?")
                
                if [ "$RPICONNECT_STATUS" = "active" ]; then
                    STATUS_ICON="🟢 activo"
                else
                    STATUS_ICON="🔴 inactivo"
                fi
                
                if [ "$RPICONNECT_VERSION" = "$RPICONNECT_LATEST" ] || [ "$RPICONNECT_LATEST" = "?" ]; then
                    echo "  🔗 RPI Connect: v$RPICONNECT_VERSION ($STATUS_ICON) ✅"
                else
                    echo "  🔗 RPI Connect: v$RPICONNECT_VERSION → v$RPICONNECT_LATEST disponible ⬆️ ($STATUS_ICON)"
                fi
            else
                echo "  🔗 RPI Connect: No instalado"
            fi
            echo ""
            
            # Preguntar si quiere modificar configuración
            echo "  ¿Qué quieres modificar?"
            echo ""
            echo "  1) Configuración equipo (serie, potencia, tramos)"
            echo "  2) Cola máxima guaranteed-delivery (maxQueue)"
            echo "  3) Actualizar Node-RED"
            echo "  4) Instalar/Actualizar RPI Connect"
            echo "  0) Nada, salir"
            echo ""
            read -p "  Opción [0-4]: " MODIFY
            
            if [ "$MODIFY" = "2" ]; then
                # Modificar maxQueue en flows.json
                FLOWS_FILE=""
                for f in /home/*/.node-red/flows.json; do
                    if [ -f "$f" ]; then
                        FLOWS_FILE="$f"
                        break
                    fi
                done
                
                if [ -n "$FLOWS_FILE" ]; then
                    # Obtener valor actual
                    CURRENT_MAXQUEUE=$(python3 -c "
import json
try:
    with open('$FLOWS_FILE') as f:
        flows = json.load(f)
    for node in flows:
        if node.get('type') == 'guaranteed-delivery':
            print(node.get('maxQueue', 500000))
            break
except:
    print('500000')
" 2>/dev/null)
                    
                    echo ""
                    echo "  Valores recomendados según RAM:"
                    echo "    - 500000 para RPIs con ~2GB RAM"
                    echo "    - 1000000 para RPIs con ~4GB RAM"
                    echo "    - 2000000 para RPIs con ~8GB RAM"
                    echo ""
                    read -p "  Nuevo maxQueue [$CURRENT_MAXQUEUE]: " NEW_MAXQUEUE
                    NEW_MAXQUEUE="${NEW_MAXQUEUE:-$CURRENT_MAXQUEUE}"
                    
                    # Actualizar en flows.json
                    python3 << EOFMAXQUEUE
import json

with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)

for node in flows:
    if node.get('type') == 'guaranteed-delivery':
        node['maxQueue'] = int($NEW_MAXQUEUE)
        break

with open('$FLOWS_FILE', 'w') as f:
    json.dump(flows, f, indent=4)

print("OK")
EOFMAXQUEUE
                    
                    echo ""
                    echo "  ✅ maxQueue actualizado a $NEW_MAXQUEUE"
                    echo ""
                    echo "  🔄 Reiniciando Node-RED para aplicar cambios..."
                    sudo systemctl restart nodered
                    sleep 2
                    echo "  ✅ Node-RED reiniciado"
                fi
                volver_menu
                continue
            fi
            
            if [ "$MODIFY" = "1" ]; then
                # Si no existe el archivo, crearlo
                if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
                    echo ""
                    echo "  ⚠️  No existe equipo_config.json, se creará uno nuevo"
                    CONFIG_DIR="/home/$(logname 2>/dev/null || echo ${SUDO_USER:-gesinne})/config"
                    CONFIG_FILE="$CONFIG_DIR/equipo_config.json"
                    mkdir -p "$CONFIG_DIR"
                    echo '{"serie": "", "potencia": 0, "Imax": 0, "tramo1": 0, "tramo2": 0, "tramo3": 0, "tramo4": 0}' > "$CONFIG_FILE"
                    echo "  ✅ Archivo creado: $CONFIG_FILE"
                fi
                
                # Leer valores actuales
                CURRENT_SERIE=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('serie', ''))" 2>/dev/null)
                CURRENT_POTENCIA=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('potencia', 0))" 2>/dev/null)
                CURRENT_IMAX=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('Imax', 0))" 2>/dev/null)
                CURRENT_T1=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('tramo1', 0))" 2>/dev/null)
                CURRENT_T2=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('tramo2', 0))" 2>/dev/null)
                CURRENT_T3=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('tramo3', 0))" 2>/dev/null)
                CURRENT_T4=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('tramo4', 0))" 2>/dev/null)
                
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
data = {
    'serie': '$NEW_SERIE',
    'potencia': int('$NEW_POTENCIA') if '$NEW_POTENCIA' else 0,
    'Imax': int('$NEW_IMAX') if '$NEW_IMAX' else 0,
    'tramo1': int('$NEW_T1') if '$NEW_T1' else 0,
    'tramo2': int('$NEW_T2') if '$NEW_T2' else 0,
    'tramo3': int('$NEW_T3') if '$NEW_T3' else 0,
    'tramo4': int('$NEW_T4') if '$NEW_T4' else 0
}
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
            
            if [ "$MODIFY" = "3" ]; then
                # Actualizar Node-RED
                echo ""
                echo "  🔄 Actualizando Node-RED..."
                echo ""
                echo "  ⚠️  Esto puede tardar varios minutos"
                echo ""
                
                # Parar Node-RED
                sudo systemctl stop nodered
                
                # Actualizar Node-RED globalmente
                echo "  → Actualizando Node-RED..."
                sudo npm install -g --unsafe-perm node-red@latest 2>&1 | tail -5
                
                # Reiniciar Node-RED
                echo ""
                echo "  🔄 Reiniciando Node-RED..."
                sudo systemctl start nodered
                sleep 3
                
                # Mostrar nueva versión
                NEW_VERSION=$(node-red --version 2>/dev/null || echo "?")
                echo ""
                echo "  ✅ Node-RED actualizado a: $NEW_VERSION"
            fi
            
            if [ "$MODIFY" = "4" ]; then
                # Instalar/Actualizar RPI Connect
                echo ""
                
                if command -v rpi-connect &> /dev/null; then
                    echo "  🔄 Actualizando RPI Connect..."
                    sudo apt-get update
                    sudo apt-get install -y rpi-connect
                else
                    echo "  📦 Instalando RPI Connect..."
                    echo ""
                    echo "  → Añadiendo repositorio..."
                    
                    # Instalar RPI Connect
                    sudo apt-get update
                    sudo apt-get install -y rpi-connect
                    
                    echo ""
                    echo "  → Habilitando servicio..."
                    sudo systemctl enable rpi-connect
                    sudo systemctl start rpi-connect
                fi
                
                # Mostrar versión y estado
                echo ""
                RPICONNECT_VERSION=$(rpi-connect --version 2>/dev/null | head -1 || echo "?")
                echo "  ✅ RPI Connect: $RPICONNECT_VERSION"
                echo ""
                echo "  ℹ️  Para vincular, ejecuta: rpi-connect signin"
                echo "     Luego accede desde: https://connect.raspberrypi.com"
            fi
            
            volver_menu
            ;;
        2)
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
            
            # Función para clonar/actualizar repo
            clone_repo() {
                rm -rf "$CACHE_DIR"
                sudo mkdir -p "$CACHE_DIR" 2>/dev/null
                sudo chown $(whoami) "$CACHE_DIR" 2>/dev/null
                git clone -q --depth 1 "$NODERED_REPO" "$CACHE_DIR" 2>/dev/null
            }
            
            if [ -d "$CACHE_DIR/.git" ]; then
                # Ya existe, actualizar
                cd "$CACHE_DIR"
                git remote set-url origin "$NODERED_REPO" 2>/dev/null
                if ! git pull -q 2>/dev/null; then
                    echo "  ⚠️  Error actualizando, re-clonando..."
                    if ! clone_repo; then
                        echo "  ❌ Credenciales inválidas. Borrando y pidiendo nuevas..."
                        sudo rm -f "$CREDS_FILE"
                        rm -rf "$CACHE_DIR"
                        echo ""
                        echo "  🔐 Introduce nuevas credenciales de GitHub"
                        echo ""
                        read -p "  Usuario GitHub: " GIT_USER
                        read -s -p "  Token/Contraseña: " GIT_TOKEN
                        echo ""
                        NODERED_REPO="https://${GIT_USER}:${GIT_TOKEN}@github.com/Gesinne/NODERED.git"
                        if ! clone_repo; then
                            echo "  ❌ Error: credenciales incorrectas"
                            exit 1
                        fi
                        # Guardar nuevas credenciales
                        sudo mkdir -p "$CACHE_DIR" 2>/dev/null
                        echo "GIT_USER=\"$GIT_USER\"" | sudo tee "$CREDS_FILE" > /dev/null
                        echo "GIT_TOKEN=\"$GIT_TOKEN\"" | sudo tee -a "$CREDS_FILE" > /dev/null
                        sudo chmod 600 "$CREDS_FILE"
                        echo "  💾 Nuevas credenciales guardadas"
                    fi
                fi
            else
                # Primera vez, clonar
                if ! clone_repo; then
                    echo "  ❌ Credenciales inválidas. Pidiendo nuevas..."
                    sudo rm -f "$CREDS_FILE"
                    echo ""
                    echo "  🔐 Introduce nuevas credenciales de GitHub"
                    echo ""
                    read -p "  Usuario GitHub: " GIT_USER
                    read -s -p "  Token/Contraseña: " GIT_TOKEN
                    echo ""
                    NODERED_REPO="https://${GIT_USER}:${GIT_TOKEN}@github.com/Gesinne/NODERED.git"
                    if ! clone_repo; then
                        echo "  ❌ Error: credenciales incorrectas"
                        exit 1
                    fi
                    # Guardar nuevas credenciales
                    sudo mkdir -p "$CACHE_DIR" 2>/dev/null
                    echo "GIT_USER=\"$GIT_USER\"" | sudo tee "$CREDS_FILE" > /dev/null
                    echo "GIT_TOKEN=\"$GIT_TOKEN\"" | sudo tee -a "$CREDS_FILE" > /dev/null
                    sudo chmod 600 "$CREDS_FILE"
                    echo "  💾 Nuevas credenciales guardadas"
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
            
            # Listar TODOS los archivos .json
            VERSIONS=$(ls "$TEMP_DIR"/*.json 2>/dev/null | xargs -n1 basename | grep -E '^[0-9]{8}' | sort -r)
            
            if [ -z "$VERSIONS" ]; then
                VERSIONS=$(ls "$TEMP_DIR"/*.json 2>/dev/null | xargs -n1 basename | sort -r)
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
            echo "  Últimas 5 versiones disponibles:"
            echo ""
            
            i=1
            declare -a VERSION_ARRAY
            for v in $VERSIONS; do
                # Extraer fecha del nombre del archivo
                FILE_DATE=$(echo "$v" | grep -oE '^[0-9]{8}' || echo "00000000")
                
                # Marcar si es la versión actual
                if [ "$FILE_DATE" = "$CURRENT_VERSION" ]; then
                    echo "  $i) $v (actual)"
                else
                    echo "  $i) $v"
                fi
                VERSION_ARRAY[$i]="$v"
                i=$((i+1))
                
                # Mostrar máximo 5
                if [ $i -gt 5 ]; then
                    break
                fi
            done
            
            if [ $i -eq 1 ]; then
                echo "  ❌ No hay versiones disponibles"
                rm -rf "$TEMP_DIR"
                volver_menu
                continue
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
            
            # Siempre limpiar ambos dashboards para evitar conflictos
            echo ""
            echo "  🧹 Limpiando dashboards anteriores..."
            npm uninstall node-red-dashboard 2>/dev/null || true
            npm uninstall @flowfuse/node-red-dashboard 2>/dev/null || true
            npm uninstall @flowfuse/node-red-dashboard-2-ui-led 2>/dev/null || true
            
            KIOSK_SCRIPT="/home/$(logname 2>/dev/null || echo $SUDO_USER)/kiosk.sh"
            
            if [ "$NEEDS_FLOWFUSE" = "yes" ]; then
                echo "  📦 Instalando FlowFuse Dashboard (puede tardar)..."
                npm install @flowfuse/node-red-dashboard @flowfuse/node-red-dashboard-2-ui-led --save
                if [ $? -eq 0 ]; then
                    echo "  ✅ FlowFuse Dashboard instalado"
                else
                    echo "  ❌ Error instalando FlowFuse Dashboard"
                    exit 1
                fi
                # Cambiar URL del kiosko a /dashboard
                if [ -f "$KIOSK_SCRIPT" ]; then
                    sed -i 's|http://localhost:1880/ui|http://localhost:1880/dashboard|g' "$KIOSK_SCRIPT"
                    echo "  🖥️  Kiosko actualizado a /dashboard"
                fi
            else
                echo "  📦 Instalando Dashboard Clásico (puede tardar)..."
                npm install node-red-dashboard --save
                if [ $? -eq 0 ]; then
                    echo "  ✅ Dashboard Clásico instalado"
                else
                    echo "  ❌ Error instalando Dashboard Clásico"
                    exit 1
                fi
                # Cambiar URL del kiosko a /ui
                if [ -f "$KIOSK_SCRIPT" ]; then
                    sed -i 's|http://localhost:1880/dashboard|http://localhost:1880/ui|g' "$KIOSK_SCRIPT"
                    echo "  🖥️  Kiosko actualizado a /ui"
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
            
            # Backup del flow actual con nombre de versión
            BACKUP_FILE="$NODERED_DIR/flows.json.backup.$(date +%Y%m%d%H%M%S).${VERSION_NAME%.json}"
            cp "$NODERED_DIR/flows.json" "$BACKUP_FILE"
            echo "  💾 Backup creado: $BACKUP_FILE"
            
            # Guardar configuración MQTT y maxQueue actual antes de sobrescribir
            PRESERVED_CONFIG=$(python3 -c "
import json
try:
    with open('$NODERED_DIR/flows.json', 'r') as f:
        flows = json.load(f)
    config = {}
    for node in flows:
        if node.get('type') == 'mqtt-broker':
            config['mqtt'] = {
                'broker': node.get('broker', 'localhost'),
                'port': node.get('port', '1883'),
                'usetls': node.get('usetls', False)
            }
        if node.get('type') == 'guaranteed-delivery':
            config['maxQueue'] = node.get('maxQueue', 500000)
    print(json.dumps(config))
except:
    pass
" 2>/dev/null)
            
            # Verificar que es JSON válido e instalar
            if python3 -c "import json; json.load(open('$FLOW_FILE'))" 2>/dev/null; then
                cp "$FLOW_FILE" "$NODERED_DIR/flows.json"
                
                # Restaurar configuración MQTT y maxQueue si existía
                if [ -n "$PRESERVED_CONFIG" ]; then
                    python3 -c "
import json
config = json.loads('$PRESERVED_CONFIG')
with open('$NODERED_DIR/flows.json', 'r') as f:
    flows = json.load(f)
for node in flows:
    if node.get('type') == 'mqtt-broker' and 'mqtt' in config:
        node['broker'] = config['mqtt']['broker']
        node['port'] = config['mqtt']['port']
        node['usetls'] = config['mqtt']['usetls']
    if node.get('type') == 'guaranteed-delivery' and 'maxQueue' in config:
        node['maxQueue'] = config['maxQueue']
with open('$NODERED_DIR/flows.json', 'w') as f:
    json.dump(flows, f, indent=4)
" 2>/dev/null
                    echo "  ✅ Flow instalado: $VERSION_NAME"
                    echo "  🔗 Configuración preservada: MQTT + maxQueue=${PRESERVED_CONFIG}"
                else
                    echo "  ✅ Flow instalado: $VERSION_NAME"
                fi
                
                # Copiar carpeta Logo si existe en el repo
                USER_HOME_DIR=$(dirname "$NODERED_DIR")
                if [ -d "$TEMP_DIR/Logo" ]; then
                    echo "  📁 Copiando carpeta Logo..."
                    cp -r "$TEMP_DIR/Logo" "$USER_HOME_DIR/"
                    chown -R $(basename "$USER_HOME_DIR"):$(basename "$USER_HOME_DIR") "$USER_HOME_DIR/Logo" 2>/dev/null
                    echo "  ✅ Carpeta Logo copiada a $USER_HOME_DIR/Logo"
                    
                    # Configurar httpStatic en settings.js
                    SETTINGS_FILE="$NODERED_DIR/settings.js"
                    if [ -f "$SETTINGS_FILE" ]; then
                        if ! grep -q "httpStatic:" "$SETTINGS_FILE"; then
                            # Añadir httpStatic después de la línea que contiene "module.exports"
                            sed -i "/module.exports\s*=\s*{/a\\    httpStatic: '$USER_HOME_DIR/Logo/'," "$SETTINGS_FILE"
                            echo "  ✅ httpStatic configurado en settings.js"
                        else
                            echo "  ℹ️  httpStatic ya está configurado"
                        fi
                    fi
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
            
            # Preguntar si quiere modificar maxQueue
            echo ""
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Cola máxima (maxQueue)"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            # Obtener valor actual y recomendado
            QUEUE_INFO=$(python3 -c "
import json, glob

# Leer RAM
with open('/proc/meminfo') as f:
    for line in f:
        if line.startswith('MemTotal:'):
            mem_kb = int(line.split()[1])
            mem_gb = mem_kb / 1024 / 1024
            break

# Recomendado según RAM
if mem_gb < 2.5:
    rec = 500000
elif mem_gb < 5.5:
    rec = 1000000
else:
    rec = 2000000

# Valor actual
cur = '?'
for f in glob.glob('/home/*/.node-red/flows.json'):
    with open(f) as fl:
        flows = json.load(fl)
    for node in flows:
        if node.get('type') == 'guaranteed-delivery':
            cur = node.get('maxQueue', '?')
            break
    break

print(f'{cur}|{rec}|{mem_gb:.1f}')
" 2>/dev/null)
            
            CUR_QUEUE=$(echo "$QUEUE_INFO" | cut -d'|' -f1)
            REC_QUEUE=$(echo "$QUEUE_INFO" | cut -d'|' -f2)
            RAM_GB=$(echo "$QUEUE_INFO" | cut -d'|' -f3)
            
            echo ""
            echo "  RAM: ${RAM_GB} GB"
            echo "  Actual: $CUR_QUEUE"
            echo "  Recomendado: $REC_QUEUE"
            echo ""
            read -p "  ¿Modificar maxQueue? [s/N]: " MODIFY_QUEUE
            
            if [ "$MODIFY_QUEUE" = "s" ] || [ "$MODIFY_QUEUE" = "S" ]; then
                echo ""
                echo "  Valores recomendados según RAM:"
                echo "    - 500000 para ~2GB RAM"
                echo "    - 1000000 para ~4GB RAM"
                echo "    - 2000000 para ~8GB RAM"
                echo ""
                read -p "  Nuevo maxQueue [$CUR_QUEUE]: " NEW_QUEUE
                NEW_QUEUE="${NEW_QUEUE:-$CUR_QUEUE}"
                
                FLOWS_FILE=""
                for f in /home/*/.node-red/flows.json; do
                    if [ -f "$f" ]; then
                        FLOWS_FILE="$f"
                        break
                    fi
                done
                
                python3 << EOFQUEUE
import json
with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)
for node in flows:
    if node.get('type') == 'guaranteed-delivery':
        node['maxQueue'] = int($NEW_QUEUE)
        break
with open('$FLOWS_FILE', 'w') as f:
    json.dump(flows, f, indent=4)
EOFQUEUE
                
                echo ""
                echo "  ✅ maxQueue actualizado a $NEW_QUEUE"
                echo ""
                echo "  🔄 Reiniciando Node-RED..."
                sudo systemctl restart nodered
                sleep 2
                echo "  ✅ Node-RED reiniciado"
            fi
            
            volver_menu
            ;;
        3)
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
                BACKUP_NAME=$(basename "$b")
                # Extraer fecha y versión del nombre
                # Formato: flows.json.backup.YYYYMMDDHHMMSS o flows.json.backup.YYYYMMDDHHMMSS.version
                BACKUP_DATE=$(echo "$BACKUP_NAME" | sed 's/flows.json.backup.//' | cut -d'.' -f1)
                BACKUP_VERSION=$(echo "$BACKUP_NAME" | sed 's/flows.json.backup.//' | cut -d'.' -f2-)
                FORMATTED_DATE=$(echo "$BACKUP_DATE" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
                BACKUP_SIZE=$(du -h "$b" | cut -f1)
                # Detectar tipo de dashboard del backup (por nombre o contenido)
                if echo "$BACKUP_NAME" | grep -q "dbrd2"; then
                    BACKUP_TYPE="[FlowFuse]"
                elif grep -q '"type": "ui-' "$b" 2>/dev/null || grep -q '"type":"ui-' "$b" 2>/dev/null; then
                    BACKUP_TYPE="[FlowFuse]"
                elif grep -q '"type": "ui_' "$b" 2>/dev/null || grep -q '"type":"ui_' "$b" 2>/dev/null; then
                    BACKUP_TYPE="[Clásico]"
                else
                    BACKUP_TYPE=""
                fi
                # Mostrar versión si existe
                if [ -n "$BACKUP_VERSION" ] && [ "$BACKUP_VERSION" != "$BACKUP_DATE" ]; then
                    echo "  $i) $FORMATTED_DATE - $BACKUP_VERSION $BACKUP_TYPE ($BACKUP_SIZE)"
                else
                    echo "  $i) $FORMATTED_DATE $BACKUP_TYPE ($BACKUP_SIZE)"
                fi
                BACKUP_ARRAY[$i]="$b"
                i=$((i+1))
                # Mostrar máximo 10
                if [ $i -gt 10 ]; then
                    break
                fi
            done
            
            echo ""
            echo "  0) 🗑️  Borrar todos los backups"
            echo ""
            read -p "  Selecciona backup [0-$((i-1))]: " BACKUP_CHOICE
            
            # Opción borrar backups
            if [ "$BACKUP_CHOICE" = "0" ]; then
                echo ""
                read -p "  ⚠️  ¿Seguro que quieres borrar TODOS los backups? [s/N]: " CONFIRM_DELETE
                if [ "$CONFIRM_DELETE" = "s" ] || [ "$CONFIRM_DELETE" = "S" ]; then
                    rm -f "$NODERED_DIR"/flows.json.backup.*
                    echo "  ✅ Backups borrados"
                else
                    echo "  ❌ Cancelado"
                fi
                volver_menu
                continue
            fi
            
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
            
            # Guardar configuración MQTT y maxQueue actual antes de restaurar
            PRESERVED_CONFIG=$(python3 -c "
import json
try:
    with open('$NODERED_DIR/flows.json', 'r') as f:
        flows = json.load(f)
    config = {}
    for node in flows:
        if node.get('type') == 'mqtt-broker':
            config['mqtt'] = {
                'broker': node.get('broker', 'localhost'),
                'port': node.get('port', '1883'),
                'usetls': node.get('usetls', False)
            }
        if node.get('type') == 'guaranteed-delivery':
            config['maxQueue'] = node.get('maxQueue', 500000)
    print(json.dumps(config))
except:
    pass
" 2>/dev/null)
            
            # Hacer backup del actual antes de restaurar
            cp "$NODERED_DIR/flows.json" "$NODERED_DIR/flows.json.backup.$(date +%Y%m%d%H%M%S)"
            
            # Restaurar
            cp "$SELECTED_BACKUP" "$NODERED_DIR/flows.json"
            
            # Restaurar configuración MQTT y maxQueue si existía
            if [ -n "$PRESERVED_CONFIG" ]; then
                python3 -c "
import json
config = json.loads('$PRESERVED_CONFIG')
with open('$NODERED_DIR/flows.json', 'r') as f:
    flows = json.load(f)
for node in flows:
    if node.get('type') == 'mqtt-broker' and 'mqtt' in config:
        node['broker'] = config['mqtt']['broker']
        node['port'] = config['mqtt']['port']
        node['usetls'] = config['mqtt']['usetls']
    if node.get('type') == 'guaranteed-delivery' and 'maxQueue' in config:
        node['maxQueue'] = config['maxQueue']
with open('$NODERED_DIR/flows.json', 'w') as f:
    json.dump(flows, f, indent=4)
" 2>/dev/null
                echo "  ✅ Flow restaurado"
                echo "  🔗 Configuración preservada: MQTT + maxQueue"
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
            
            volver_menu
            ;;
        5)
            echo ""
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Ver los 96 registros de la placa"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  ¿Qué tarjeta quieres leer?"
            echo ""
            echo "  1) Tarjeta L1 (Fase 1)"
            echo "  2) Tarjeta L2 (Fase 2)"
            echo "  3) Tarjeta L3 (Fase 3)"
            echo "  4) TODAS en columnas (L1, L2, L3)"
            echo "  0) Volver al menú"
            echo ""
            read -p "  Opción [0-4]: " TARJETA
            
            case $TARJETA in
                0) continue ;;
                1) UNIT_IDS="1"; FASES="L1"; MODO_COLUMNAS="no" ;;
                2) UNIT_IDS="2"; FASES="L2"; MODO_COLUMNAS="no" ;;
                3) UNIT_IDS="3"; FASES="L3"; MODO_COLUMNAS="no" ;;
                4) UNIT_IDS="1 2 3"; FASES="L1 L2 L3"; MODO_COLUMNAS="yes" ;;
                *) echo "  ❌ Opción no válida"; continue ;;
            esac
            
            # Siempre detectar el máximo de registros
            NUM_REGS=200
            DETECT_MAX="yes"
            
            echo ""
            echo "  ⚠️  Parando Node-RED temporalmente..."
            
            # Parar Node-RED
            sudo systemctl stop nodered 2>/dev/null
            
            # Parar contenedor Docker si existe (silencioso)
            docker stop gesinne-rpi >/dev/null 2>&1 || true
            
            sleep 2
            echo "  ✅ Servicios parados"
            echo ""
            
            # Si es modo columnas, leer las 3 placas y mostrar en tabla
            if [ "$MODO_COLUMNAS" = "yes" ]; then
                echo "  📡 Leyendo las 3 tarjetas..."
                echo ""
                
                python3 << 'EOFCOL'
import sys
try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    try:
        from pymodbus.client.sync import ModbusSerialClient
    except ImportError:
        print("  ❌ pymodbus no instalado")
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
    print("  ❌ No se pudo conectar al puerto serie")
    sys.exit(1)

import time

# Leer las 3 placas con reintentos
data_all = {}
for unit_id in [1, 2, 3]:
    fase = {1: "L1", 2: "L2", 3: "L3"}[unit_id]
    print(f"  📡 Leyendo tarjeta {fase}...", end=" ", flush=True)
    
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
        
        if success and len(data) >= 96:
            print("✅")
            break
        else:
            if retry < max_retries - 1:
                print(f"⚠️ reintentando ({retry+2}/{max_retries})...", end=" ", flush=True)
                time.sleep(1)
            else:
                print("❌ sin respuesta")
    
    data_all[unit_id] = data if len(data) >= 96 else None

client.close()

# Verificar que las 3 placas respondieron
placas_ok = [u for u in [1, 2, 3] if data_all[u] is not None]
placas_fail = [u for u in [1, 2, 3] if data_all[u] is None]

if placas_fail:
    print("")
    print(f"  ⚠️  No se pudo leer: {', '.join(['L'+str(u) for u in placas_fail])}")
    if not placas_ok:
        print("  ❌ No hay datos para mostrar")
        sys.exit(1)

# Rellenar placas sin datos con None para mostrar "---"
for u in placas_fail:
    data_all[u] = [None] * 96

print("")

# Nombres cortos de registros
regs = {
    0: "Estado", 1: "Topología", 2: "Alarma", 3: "V salida", 4: "V entrada",
    5: "Hz", 6: "I Salida", 7: "I Chopper", 8: "I Prim trafo", 9: "P act(H)",
    10: "P act(L)", 11: "P react(H)", 12: "P react(L)", 13: "P apar(H)",
    14: "P apar(L)", 15: "FP", 16: "Tipo FP", 17: "Temp", 18: "T alarma",
    19: "Enable ext", 20: "T reenc", 21: "Enable PCB",
    30: "Flag Est", 31: "Est desead", 32: "Consigna", 33: "Bucle ctrl", 34: "Mando",
    40: "Flag Conf", 41: "Nº Serie", 42: "V nominal", 43: "V prim auto",
    44: "V sec auto", 45: "V sec trafo", 46: "Topología", 47: "Dead-time",
    48: "Dir Modbus", 49: "I nom sal", 50: "I nom chop", 51: "I max chop",
    52: "I max pico", 53: "T apag CC", 54: "Cnt SC", 55: "Est inicial",
    56: "V inicial", 57: "T máxima", 58: "Dec T reenc", 59: "Cnt ST",
    60: "Tipo V", 61: "Vel Modbus", 62: "Package", 63: "Áng alta",
    64: "Áng baja", 65: "% carga", 66: "Sens trans", 67: "Sens deriv", 69: "ReCo",
    70: "Flag Cal", 71: "Ca00", 72: "Ca01", 73: "Ca03", 74: "Ca04",
    75: "Ca06", 76: "Ca07", 77: "Ca08", 78: "Ca09", 79: "Ca10",
    80: "Ca11", 81: "Ca12", 82: "Ca13", 83: "Ca14", 84: "Ca15", 85: "R", 86: "ReCa",
    90: "Flag Ctrl", 91: "Cn00", 92: "Cn01", 93: "Cn02", 94: "Cn03", 95: "ReCn"
}

# Imprimir en columnas
print("  ╔════════════════════════════════════════════════════════════════════════════════╗")
print("  ║  PARÁMETROS DE LAS 3 PLACAS                                                    ║")
print("  ╚════════════════════════════════════════════════════════════════════════════════╝")
print("")
print(f"  {'Reg':<4} {'Parámetro':<14} {'L1':>8} {'L2':>8} {'L3':>8}   {'Diferencia'}")
print(f"  {'─'*4} {'─'*14} {'─'*8} {'─'*8} {'─'*8}   {'─'*12}")

def print_section(title, start, end):
    print(f"\n  ── {title} ──")
    for i in range(start, end):
        if i in regs:
            v1 = data_all[1][i] if data_all[1] and i < len(data_all[1]) and data_all[1][i] is not None else None
            v2 = data_all[2][i] if data_all[2] and i < len(data_all[2]) and data_all[2][i] is not None else None
            v3 = data_all[3][i] if data_all[3] and i < len(data_all[3]) and data_all[3][i] is not None else None
            
            s1 = f"{v1:>8}" if v1 is not None else "     ---"
            s2 = f"{v2:>8}" if v2 is not None else "     ---"
            s3 = f"{v3:>8}" if v3 is not None else "     ---"
            
            # Solo marcar diferencia si hay al menos 2 valores válidos
            vals = [v for v in [v1, v2, v3] if v is not None]
            diff = "⚠️ DIFF" if len(vals) >= 2 and len(set(vals)) > 1 else ""
            
            print(f"  {i:<4} {regs[i]:<14} {s1} {s2} {s3}   {diff}")

print_section("TIEMPO REAL", 0, 22)
print_section("ESTADO", 30, 35)
print_section("CONFIGURACIÓN", 40, 70)
print_section("CALIBRACIÓN", 70, 87)
print_section("CONTROL", 90, 96)

print("")
EOFCOL
                
                # Reiniciar servicios
                echo ""
                echo "  🔄 Reiniciando servicios..."
                sudo systemctl start nodered
                docker start gesinne-rpi 2>/dev/null || true
                if systemctl is-active --quiet kiosk.service 2>/dev/null; then
                    sudo systemctl restart kiosk.service
                fi
                echo "  ✅ Listo"
                
                volver_menu
                continue
            fi
            
            # Modo normal: una placa a la vez
            for UNIT_ID in $UNIT_IDS; do
            
            case $UNIT_ID in
                1) FASE="L1" ;;
                2) FASE="L2" ;;
                3) FASE="L3" ;;
            esac
            
            echo "  📡 Leyendo registros de Tarjeta $FASE (Unit ID: $UNIT_ID)..."
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
        
        # Definir registros con: (descripción larga, nombre corto)
        regs = {
            0: ("Estado actual del chopper", "Estado actual"),
            1: ("Modo de funcionamiento (topología) actual", "Topología actual"),
            2: ("Alarma", "Alarma"),
            3: ("Tensión de salida (Vo)", "V salida"),
            4: ("Tensión de entrada (Vin)", "V entrada"),
            5: ("Frecuencia", "Hz"),
            6: ("Corriente de salida del Equipo", "I Salida"),
            7: ("Corriente de salida del Chopper", "I Chopper"),
            8: ("Corriente por primario del trafo", "I Primario trafo"),
            9: ("Potencia activa de salida (parte alta)", "P activa (alta)"),
            10: ("Potencia activa de salida (parte baja)", "P activa (baja)"),
            11: ("Potencia reactiva de salida (parte alta)", "P reactiva (alta)"),
            12: ("Potencia reactiva de salida (parte baja)", "P reactiva (baja)"),
            13: ("Potencia aparente de salida (parte alta)", "P aparente (alta)"),
            14: ("Potencia aparente de salida (parte baja)", "P aparente (baja)"),
            15: ("Factor de potencia", "Factor de Potencia"),
            16: ("Tipo de factor de potencia", "Tipo de FP"),
            17: ("Temperatura interna", "Temperatura"),
            18: ("Temperatura para despejar alarma", "Temperatura de alarma"),
            19: ("Estado del Enable de regulación externo", "Enable externo"),
            20: ("Tiempo restante para reencendido", "Tiempo para despejar"),
            21: ("Estado del Enable de regulación Switch PCB", "Enable PCB"),
            22: ("N/A", "N/A"), 23: ("N/A", "N/A"), 24: ("N/A", "N/A"), 25: ("N/A", "N/A"),
            26: ("N/A", "N/A"), 27: ("N/A", "N/A"), 28: ("N/A", "N/A"), 29: ("N/A", "N/A"),
            30: ("Flag escritura registros de ESTADO", "Flag Estado"),
            31: ("Estado deseado del Chopper", "Estado deseado"),
            32: ("Tensión de consigna deseada", "Consigna deseada"),
            33: ("Bucle de control del Chopper", "Bucle de control"),
            34: ("Mando del control del Chopper", "Mando chopper"),
            35: ("N/A", "N/A"), 36: ("N/A", "N/A"), 37: ("N/A", "N/A"), 38: ("N/A", "N/A"), 39: ("N/A", "N/A"),
            40: ("Flag escritura registros de CONFIGURACIÓN", "Flag Configuración"),
            41: ("Número de serie", "Nº de serie placas"),
            42: ("Tensión nominal", "V nominal"),
            43: ("Tensión de primario del autotransformador", "V primario autotrafo"),
            44: ("Tensión de primario del transformador", "V secundario autotrafo"),
            45: ("Tensión de secundario del transformador", "V secundario trafo"),
            46: ("Topología del equipo", "Topología"),
            47: ("Dead-time (DT)", "Dead-time"),
            48: ("Dirección MODBUS", "Modbus"),
            49: ("Corriente nominal de medida de salida del Equipo", "I nominal salida"),
            50: ("Corriente nominal de medida de salida del Chopper", "I nominal chopper"),
            51: ("Corriente máxima chopper (valor eficaz)", "I máxima chopper"),
            52: ("Corriente máxima chopper (valor pico)", "I máxima chopper"),
            53: ("Tiempo de apagado después de CC/TT", "Tiempo de apagado CC/TT"),
            54: ("Número de apagados por sobrecorriente", "Contador apagados SC"),
            55: ("Estado inicial del Chopper", "Estado inicial"),
            56: ("Tensión de consigna inicial", "V inicial"),
            57: ("Temperatura interna máxima", "Temperatura máxima"),
            58: ("Decremento de temperatura para reencendido", "Decremento T reenc"),
            59: ("Número de apagados por sobretemperatura", "Contador apagados ST"),
            60: ("Tipo de alimentación de la placa", "Tipo V placa"),
            61: ("Velocidad de comunicación MODBUS", "Velocidad Modbus"),
            62: ("Empaquetado (package) de los transistores", "Package transistores"),
            63: ("Ángulo de cambio de tensión para cargas altas", "Ángulo cargas altas"),
            64: ("Ángulo de cambio de tensión para cargas bajas", "Ángulo cargas bajas"),
            65: ("Porcentaje de corriente máxima para carga baja", "% para carga baja"),
            66: ("Sensibilidad detección transitorios", "Sensibilidad transitorios"),
            67: ("Sensibilidad detección derivada corriente", "Sensibilidad derivada"),
            68: ("N/A", "N/A"),
            69: ("Restablece la configuración por defecto", "?ReCo"),
            70: ("Flag escritura registros de CALIBRACIÓN", "Flag Calibración"),
            71: ("Parámetro K de la tensión de salida V0", "?Ca00"),
            72: ("Parámetro K de la tensión de entrada Vin", "?Ca01"),
            73: ("Parámetro b de la tensión de salida V0", "?Ca03"),
            74: ("Parámetro b de la tensión de entrada Vin", "?Ca04"),
            75: ("Parámetro K de la corriente de salida del Chopper", "?Ca06"),
            76: ("Parámetro K de la corriente de salida del Equipo", "?Ca07"),
            77: ("Parámetro b de la corriente de salida del Chopper", "?Ca08"),
            78: ("Parámetro b de la corriente de salida del Equipo", "?Ca09"),
            79: ("Valor del ruido de la corriente del Chopper", "?Ca10"),
            80: ("Valor del ruido de la corriente del Equipo", "?Ca11"),
            81: ("Parámetro K de la potencia de salida", "?Ca12"),
            82: ("Parámetro b de la potencia de salida", "?Ca13"),
            83: ("Desfase de muestras entre tensión y corriente", "?Ca14"),
            84: ("Parámetro de calibración de la medida de frecuencia", "?Ca15"),
            85: ("Calibra el ruido de los canales de corriente", "?R"),
            86: ("Restablece la calibración por defecto", "?ReCa"),
            87: ("N/A", "N/A"), 88: ("N/A", "N/A"), 89: ("N/A", "N/A"),
            90: ("Flag escritura registros de CONTROL", "Flag Control"),
            91: ("Parámetro A del control de tensión", "?Cn00"),
            92: ("Parámetro B del control de tensión", "?Cn01"),
            93: ("Escalón máximo del mando de tensión (EMM)", "?Cn02"),
            94: ("Escalón máximo del mando tensión nula (EMMVT0)", "?Cn03"),
            95: ("Escalón máximo del mando tensión no nula (EMMVT1)", "?ReCn"),
        }
        
        # Imprimir con formato de tabla por secciones
        def print_header(titulo):
            print("")
            print(f"  {'='*80}")
            print(f"  {titulo}")
            print(f"  {'='*80}")
            print("  Reg | Parámetro                | Valor      | Descripción")
            print("  ----|--------------------------|------------|--------------------------------------------------")
        
        # Identificar la placa por el registro 48 (Dirección MODBUS)
        dir_modbus = data[48] if len(data) > 48 else 0
        placa_nombre = {1: "L1 (Fase 1)", 2: "L2 (Fase 2)", 3: "L3 (Fase 3)"}.get(dir_modbus, f"Desconocida ({dir_modbus})")
        
        print("")
        print(f"  ╔══════════════════════════════════════════════════════════════════════════════╗")
        print(f"  ║  PLACA IDENTIFICADA: {placa_nombre:20s}  -  Dirección Modbus: {dir_modbus}            ║")
        print(f"  ╚══════════════════════════════════════════════════════════════════════════════╝")
        
        # DATOS EN TIEMPO REAL (0-29)
        print_header("DATOS EN TIEMPO REAL (0-29)")
        for i in range(0, 30):
            if i in regs and i < len(data):
                desc, nombre = regs[i]
                print(f"  {i:3d} | {nombre:24s} | {data[i]:10d} | {desc}")
        
        # ESTADO (30-39)
        print_header("REGISTROS DE ESTADO (30-39)")
        for i in range(30, 40):
            if i in regs and i < len(data):
                desc, nombre = regs[i]
                print(f"  {i:3d} | {nombre:24s} | {data[i]:10d} | {desc}")
        
        # CONFIGURACIÓN (40-69)
        print_header("REGISTROS DE CONFIGURACIÓN ?Co (40-69)")
        for i in range(40, 70):
            if i in regs and i < len(data):
                desc, nombre = regs[i]
                print(f"  {i:3d} | {nombre:24s} | {data[i]:10d} | {desc}")
        
        # CALIBRACIÓN (70-89)
        if len(data) > 70:
            print_header("REGISTROS DE CALIBRACIÓN ?Ca (70-89)")
            for i in range(70, 90):
                if i in regs and i < len(data):
                    desc, nombre = regs[i]
                    print(f"  {i:3d} | {nombre:24s} | {data[i]:10d} | {desc}")
        
        # CONTROL (90-95)
        if len(data) > 90:
            print_header("REGISTROS DE CONTROL ?Cn (90-95)")
            for i in range(90, 96):
                if i in regs and i < len(data):
                    desc, nombre = regs[i]
                    print(f"  {i:3d} | {nombre:24s} | {data[i]:10d} | {desc}")
        
        print("")
    else:
        print("  ❌ No se pudieron leer registros")
    
except Exception as e:
    print(f"  ❌ Error: {e}")
finally:
    client.close()
EOF
            
            done  # fin del bucle for UNIT_ID
            
            # Guardar automáticamente en archivo
            ARCHIVO="/home/$(logname 2>/dev/null || echo 'pi')/parametros_configuracion.txt"
            echo ""
            echo "  💾 Guardando en: $ARCHIVO"
            
            # Crear archivo con formato bonito
            echo "================================================================================" > "$ARCHIVO"
            echo "PARÁMETROS DE CONFIGURACIÓN - $(date)" >> "$ARCHIVO"
            echo "================================================================================" >> "$ARCHIVO"
            
            for UNIT_ID in $UNIT_IDS; do
                case $UNIT_ID in
                    1) FASE="L1" ;;
                    2) FASE="L2" ;;
                    3) FASE="L3" ;;
                esac
                
                python3 << EOFTXT >> "$ARCHIVO"
import sys
try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    from pymodbus.client.sync import ModbusSerialClient

client = ModbusSerialClient(port='/dev/ttyAMA0', baudrate=115200, bytesize=8, parity='N', stopbits=1, timeout=1)
if client.connect():
    data = []
    for start in range(0, 96, 40):
        count = min(40, 96 - start)
        result = client.read_holding_registers(address=start, count=count, slave=$UNIT_ID)
        if not result.isError():
            data.extend(result.registers)
        else:
            break
    client.close()
    
    if len(data) > 48:
        dir_modbus = data[48]
        placa = {1: "L1 (Fase 1)", 2: "L2 (Fase 2)", 3: "L3 (Fase 3)"}.get(dir_modbus, f"Desconocida")
        
        print("")
        print(f"╔══════════════════════════════════════════════════════════════════════════════╗")
        print(f"║  PLACA: {placa:20s}  -  Dirección Modbus: {dir_modbus}                        ║")
        print(f"╚══════════════════════════════════════════════════════════════════════════════╝")
        print("")
        print("Reg | Parámetro                | Valor      | Descripción")
        print("----|--------------------------|------------|--------------------------------------------------")
        
        regs = {
            0: ("Estado actual del chopper", "Estado actual"),
            1: ("Modo de funcionamiento", "Topología actual"),
            2: ("Alarma", "Alarma"),
            3: ("Tensión de salida (Vo)", "V salida"),
            4: ("Tensión de entrada (Vin)", "V entrada"),
            5: ("Frecuencia", "Hz"),
            6: ("Corriente salida Equipo", "I Salida"),
            7: ("Corriente salida Chopper", "I Chopper"),
            8: ("Corriente primario trafo", "I Primario"),
            9: ("Potencia activa (alta)", "P activa (alta)"),
            10: ("Potencia activa (baja)", "P activa (baja)"),
            11: ("Potencia reactiva (alta)", "P reactiva (alta)"),
            12: ("Potencia reactiva (baja)", "P reactiva (baja)"),
            13: ("Potencia aparente (alta)", "P aparente (alta)"),
            14: ("Potencia aparente (baja)", "P aparente (baja)"),
            15: ("Factor de potencia", "Factor Potencia"),
            16: ("Tipo factor potencia", "Tipo FP"),
            17: ("Temperatura interna", "Temperatura"),
            18: ("Temperatura alarma", "Temp alarma"),
            19: ("Enable externo", "Enable externo"),
            20: ("Tiempo reencendido", "Tiempo reenc"),
            21: ("Enable PCB", "Enable PCB"),
            30: ("Flag Estado", "Flag Estado"),
            31: ("Estado deseado", "Estado deseado"),
            32: ("Consigna deseada", "Consigna"),
            33: ("Bucle control", "Bucle control"),
            34: ("Mando chopper", "Mando chopper"),
            40: ("Flag Configuración", "Flag Config"),
            41: ("Número de serie", "Nº serie"),
            42: ("Tensión nominal", "V nominal"),
            43: ("V primario autotrafo", "V prim auto"),
            44: ("V secundario autotrafo", "V sec auto"),
            45: ("V secundario trafo", "V sec trafo"),
            46: ("Topología", "Topología"),
            47: ("Dead-time", "Dead-time"),
            48: ("Dirección MODBUS", "Modbus"),
            49: ("I nominal salida", "I nom salida"),
            50: ("I nominal chopper", "I nom chopper"),
            51: ("I máxima chopper eficaz", "I max eficaz"),
            52: ("I máxima chopper pico", "I max pico"),
            53: ("Tiempo apagado CC/TT", "T apagado"),
            54: ("Contador apagados SC", "Cnt SC"),
            55: ("Estado inicial", "Estado ini"),
            56: ("V inicial", "V inicial"),
            57: ("Temperatura máxima", "Temp máx"),
            58: ("Decremento T", "Decr T"),
            59: ("Contador apagados ST", "Cnt ST"),
            60: ("Tipo V placa", "Tipo V"),
            61: ("Velocidad Modbus", "Vel Modbus"),
            62: ("Package transistores", "Package"),
            63: ("Ángulo cargas altas", "Áng altas"),
            64: ("Ángulo cargas bajas", "Áng bajas"),
            65: ("% carga baja", "% carga baja"),
            66: ("Sensibilidad transitorios", "Sens trans"),
            67: ("Sensibilidad derivada", "Sens deriv"),
            69: ("Reset config", "?ReCo"),
            70: ("Flag Calibración", "Flag Calib"),
            71: ("K tensión salida", "?Ca00"),
            72: ("K tensión entrada", "?Ca01"),
            73: ("b tensión salida", "?Ca03"),
            74: ("b tensión entrada", "?Ca04"),
            75: ("K corriente chopper", "?Ca06"),
            76: ("K corriente equipo", "?Ca07"),
            77: ("b corriente chopper", "?Ca08"),
            78: ("b corriente equipo", "?Ca09"),
            79: ("Ruido I chopper", "?Ca10"),
            80: ("Ruido I equipo", "?Ca11"),
            81: ("K potencia salida", "?Ca12"),
            82: ("b potencia salida", "?Ca13"),
            83: ("Desfase V-I", "?Ca14"),
            84: ("Calib frecuencia", "?Ca15"),
            85: ("Calib ruido I", "?R"),
            86: ("Reset calibración", "?ReCa"),
            90: ("Flag Control", "Flag Control"),
            91: ("Parámetro A control", "?Cn00"),
            92: ("Parámetro B control", "?Cn01"),
            93: ("Escalón max EMM", "?Cn02"),
            94: ("Escalón max V0", "?Cn03"),
            95: ("Escalón max V1", "?ReCn"),
        }
        
        for i in range(len(data)):
            if i in regs:
                desc, nombre = regs[i]
                print(f"{i:3d} | {nombre:24s} | {data[i]:10d} | {desc}")
EOFTXT
            done
            
            echo "" >> "$ARCHIVO"
            echo "================================================================================" >> "$ARCHIVO"
            echo "  ✅ Archivo guardado: $ARCHIVO"
            
            echo ""
            echo "  🔄 Reiniciando servicios..."
            sudo systemctl start nodered
            sleep 1
            
            # Reiniciar contenedor Docker si existía
            if docker ps -a -q -f name=gesinne-rpi 2>/dev/null | grep -q .; then
                echo "  🐳 Reiniciando contenedor gesinne-rpi..."
                docker start gesinne-rpi 2>/dev/null
            fi
            
            # Reiniciar kiosko si existe
            if systemctl is-active --quiet kiosk.service 2>/dev/null; then
                sudo systemctl restart kiosk.service
            fi
            
            echo "  ✅ Listo"
            
            volver_menu
            ;;
        6)
            # Leer registros y enviar por email
            echo ""
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Descargar parámetros (enviar por EMAIL)"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  ¿Qué tarjeta quieres leer?"
            echo ""
            echo "  1) Tarjeta L1 (Fase 1)"
            echo "  2) Tarjeta L2 (Fase 2)"
            echo "  3) Tarjeta L3 (Fase 3)"
            echo "  4) TODAS las tarjetas (L1, L2, L3)"
            echo ""
            read -p "  Opción [1-4]: " TARJETA_EMAIL
            
            case $TARJETA_EMAIL in
                1) TARJETAS_EMAIL="1" ;;
                2) TARJETAS_EMAIL="2" ;;
                3) TARJETAS_EMAIL="3" ;;
                4) TARJETAS_EMAIL="1 2 3" ;;
                *) echo "  ❌ Opción no válida"; exit 1 ;;
            esac
            
            echo ""
            echo "  📧 Preparando envío de email..."
            echo ""
            echo "  ⚠️  Parando Node-RED temporalmente..."
            
            # Parar Node-RED
            sudo systemctl stop nodered 2>/dev/null
            
            # Parar contenedor Docker si existe (silencioso)
            docker stop gesinne-rpi >/dev/null 2>&1 || true
            
            sleep 2
            echo "  ✅ Servicios parados"
            echo ""
            
            # Obtener número de serie
            CONFIG_FILE=""
            for f in /home/*/config/equipo_config.json; do
                if [ -f "$f" ]; then
                    CONFIG_FILE="$f"
                    break
                fi
            done
            
            if [ -n "$CONFIG_FILE" ]; then
                SERIAL=$(python3 -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        data = json.load(f)
    # Buscar en varios campos posibles
    sn = data.get('serie') or data.get('numero_serie') or data.get('s_n') or 'unknown'
    print(sn)
except:
    print('unknown')
" 2>/dev/null)
            else
                SERIAL="unknown"
            fi
            
            echo "  📧 Leyendo registros y enviando email..."
            
            python3 << EOFEMAIL
import os
import sys
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from datetime import datetime

# Configuración
SMTP_SERVER = "smtp.gmail.com"
SMTP_PORT = 587
SMTP_USER = "gesinneasturias@gmail.com"
SMTP_PASSWORD = "pegdowikwjuqpeoq"
SMTP_FROM = "gesinneasturias@gmail.com"
SMTP_TO = "patricia.garcia@gesinne.com,victorbarrero@gesinne.com,joseluis.nicolas@gesinne.com"
NUMERO_SERIE = "$SERIAL"
TARJETAS = "$TARJETAS_EMAIL"

try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    from pymodbus.client.sync import ModbusSerialClient

REGISTROS = {
    0: ("Estado actual del chopper", "Estado actual"),
    1: ("Modo de funcionamiento (topología) actual", "Topología actual"),
    2: ("Alarma", "Alarma"),
    3: ("Tensión de salida (Vo)", "V salida"),
    4: ("Tensión de entrada (Vin)", "V entrada"),
    5: ("Frecuencia", "Hz"),
    6: ("Corriente de salida del Equipo", "I Salida"),
    7: ("Corriente de salida del Chopper", "I Chopper"),
    8: ("Corriente por primario del trafo (reflejada secundario)", "I Primario trafo"),
    9: ("Potencia activa de salida del equipo (parte alta)", "P activa (alta)"),
    10: ("Potencia activa de salida del equipo (parte baja)", "P activa (baja)"),
    11: ("Potencia reactiva de salida (parte alta)", "P reactiva (alta)"),
    12: ("Potencia reactiva de salida (parte baja)", "P reactiva (baja)"),
    13: ("Potencia aparente de salida del equipo (parte alta)", "P aparente (alta)"),
    14: ("Potencia aparente de salida del equipo (parte baja)", "P aparente (baja)"),
    15: ("Factor de potencia", "Factor de Potencia"),
    16: ("Tipo de factor de potencia", "Tipo de FP"),
    17: ("Temperatura interna", "Temperatura"),
    18: ("Temperatura para despejar alarma", "Temperatura de alarma"),
    19: ("Estado del Enable de regulación externo", "Enable externo"),
    20: ("Tiempo restante para reencendido", "Tiempo para despejar"),
    21: ("Estado del Enable de regulación Switch PCB", "Enable PCB"),
    22: ("N/A", "N/A"), 23: ("N/A", "N/A"), 24: ("N/A", "N/A"), 25: ("N/A", "N/A"),
    26: ("N/A", "N/A"), 27: ("N/A", "N/A"), 28: ("N/A", "N/A"), 29: ("N/A", "N/A"),
    30: ("Flag escritura registros de ESTADO", "Flag Estado"),
    31: ("Estado deseado del Chopper", "Estado deseado"),
    32: ("Tensión de consigna deseada", "Consigna deseada"),
    33: ("Bucle de control del Chopper", "Bucle de control"),
    34: ("Mando del control del Chopper", "Mando chopper"),
    35: ("N/A", "N/A"), 36: ("N/A", "N/A"), 37: ("N/A", "N/A"), 38: ("N/A", "N/A"), 39: ("N/A", "N/A"),
    40: ("Flag escritura registros de CONFIGURACIÓN", "Flag Configuración"),
    41: ("Número de serie", "Nº de serie placas"),
    42: ("Tensión nominal", "V nominal"),
    43: ("Tensión de primario del autotransformador", "V primario autotrafo"),
    44: ("Tensión de primario del transformador", "V secundario autotrafo"),
    45: ("Tensión de secundario del transformador", "V secundario trafo"),
    46: ("Topología del equipo", "Topología"),
    47: ("Dead-time (DT)", "Dead-time"),
    48: ("Dirección MODBUS", "Modbus"),
    49: ("Corriente nominal de medida de salida del Equipo", "I nominal salida"),
    50: ("Corriente nominal de medida de salida del Chopper", "I nominal chopper"),
    51: ("Corriente máxima chopper (valor eficaz)", "I máxima chopper"),
    52: ("Corriente máxima chopper (valor pico)", "I máxima chopper"),
    53: ("Tiempo de apagado después de CC/TT", "Tiempo de apagado CC/TT"),
    54: ("Número de apagados por sobrecorriente", "Contador apagados SC"),
    55: ("Estado inicial del Chopper", "Estado inicial"),
    56: ("Tensión de consigna inicial", "V inicial"),
    57: ("Temperatura interna máxima", "Temperatura máxima"),
    58: ("Decremento de temperatura para reencendido", "Decremento T reenc"),
    59: ("Número de apagados por sobretemperatura", "Contador apagados ST"),
    60: ("Tipo de alimentación de la placa", "Tipo V placa"),
    61: ("Velocidad de comunicación MODBUS", "Velocidad Modbus"),
    62: ("Empaquetado (package) de los transistores", "Package transistores"),
    63: ("Ángulo de cambio de tensión para cargas altas", "Ángulo cargas altas"),
    64: ("Ángulo de cambio de tensión para cargas bajas", "Ángulo cargas bajas"),
    65: ("Porcentaje de corriente máxima para carga baja", "% para carga baja"),
    66: ("Sensibilidad detección transitorios", "Sensibilidad transitorios"),
    67: ("Sensibilidad detección derivada corriente", "Sensibilidad derivada"),
    68: ("N/A", "N/A"),
    69: ("Restablece la configuración por defecto", "?ReCo"),
    70: ("Flag escritura registros de CALIBRACIÓN", "Flag Calibración"),
    71: ("Parámetro K de la tensión de salida V0", "?Ca00"),
    72: ("Parámetro K de la tensión de entrada Vin", "?Ca01"),
    73: ("Parámetro b de la tensión de salida V0", "?Ca03"),
    74: ("Parámetro b de la tensión de entrada Vin", "?Ca04"),
    75: ("Parámetro K de la corriente de salida del Chopper", "?Ca06"),
    76: ("Parámetro K de la corriente de salida del Equipo", "?Ca07"),
    77: ("Parámetro b de la corriente de salida del Chopper", "?Ca08"),
    78: ("Parámetro b de la corriente de salida del Equipo", "?Ca09"),
    79: ("Valor del ruido de la corriente del Chopper", "?Ca10"),
    80: ("Valor del ruido de la corriente del Equipo", "?Ca11"),
    81: ("Parámetro K de la potencia de salida", "?Ca12"),
    82: ("Parámetro b de la potencia de salida", "?Ca13"),
    83: ("Desfase de muestras entre tensión y corriente", "?Ca14"),
    84: ("Parámetro de calibración de la medida de frecuencia", "?Ca15"),
    85: ("Calibra el ruido de los canales de corriente", "?R"),
    86: ("Restablece la calibración por defecto", "?ReCa"),
    87: ("N/A", "N/A"), 88: ("N/A", "N/A"), 89: ("N/A", "N/A"),
    90: ("Flag escritura registros de CONTROL", "Flag Control"),
    91: ("Parámetro A del control de tensión", "?Cn00"),
    92: ("Parámetro B del control de tensión", "?Cn01"),
    93: ("Escalón máximo del mando de tensión (EMM)", "?Cn02"),
    94: ("Escalón máximo del mando tensión nula (EMMVT0)", "?Cn03"),
    95: ("Escalón máximo del mando tensión no nula (EMMVT1)", "?ReCn"),
}

import time

# Leer las 3 fases con reintentos
placas_leidas = {}
max_intentos = 10
intento = 0

while len(placas_leidas) < 3 and intento < max_intentos:
    intento += 1
    fases_pendientes = [u for u in [1, 2, 3] if u not in placas_leidas]
    
    if intento > 1:
        print(f"  🔄 Reintento {intento}/{max_intentos} - Fases pendientes: {', '.join([f'L{u}' for u in fases_pendientes])}")
        time.sleep(1)
    
    client = ModbusSerialClient(port='/dev/ttyAMA0', baudrate=115200, bytesize=8, parity='N', stopbits=1, timeout=1)
    
    if client.connect():
        for unit_id in fases_pendientes:
            data = []
            for start in range(0, 96, 40):
                count = min(40, 96 - start)
                result = client.read_holding_registers(address=start, count=count, slave=unit_id)
                if not result.isError():
                    data.extend(result.registers)
                else:
                    break
            
            if len(data) > 48:
                placas_leidas[unit_id] = data
                print(f"  ✅ L{unit_id} leída correctamente")
        
        client.close()

# Verificar que tenemos las 3 fases
if len(placas_leidas) < 3:
    fases_ok = [f"L{k}" for k in sorted(placas_leidas.keys())]
    fases_fail = [f"L{k}" for k in [1,2,3] if k not in placas_leidas]
    print(f"⚠️  Solo se pudieron leer {len(placas_leidas)} fases: {', '.join(fases_ok)}")
    print(f"❌ Fases sin respuesta después de {max_intentos} intentos: {', '.join(fases_fail)}")
    print("❌ No se envía email hasta tener las 3 fases")
    sys.exit(1)

print(f"  ✅ Las 3 fases leídas correctamente")

# Obtener números de serie de cada placa
sn_l1 = placas_leidas[1][41]
sn_l2 = placas_leidas[2][41]
sn_l3 = placas_leidas[3][41]

# Nombres cortos para columnas
REGS_CORTOS = {
    0: "Estado", 1: "Topología", 2: "Alarma", 3: "V salida", 4: "V entrada",
    5: "Hz", 6: "I Salida", 7: "I Chopper", 8: "I Prim trafo", 9: "P act(H)",
    10: "P act(L)", 11: "P react(H)", 12: "P react(L)", 13: "P apar(H)",
    14: "P apar(L)", 15: "FP", 16: "Tipo FP", 17: "Temp", 18: "T alarma",
    19: "Enable ext", 20: "T reenc", 21: "Enable PCB",
    30: "Flag Est", 31: "Est desead", 32: "Consigna", 33: "Bucle ctrl", 34: "Mando",
    40: "Flag Conf", 41: "Nº Serie", 42: "V nominal", 43: "V prim auto",
    44: "V sec auto", 45: "V sec trafo", 46: "Topología", 47: "Dead-time",
    48: "Dir Modbus", 49: "I nom sal", 50: "I nom chop", 51: "I max chop",
    52: "I max pico", 53: "T apag CC", 54: "Cnt SC", 55: "Est inicial",
    56: "V inicial", 57: "T máxima", 58: "Dec T reenc", 59: "Cnt ST",
    60: "Tipo V", 61: "Vel Modbus", 62: "Package", 63: "Áng alta",
    64: "Áng baja", 65: "% carga", 66: "Sens trans", 67: "Sens deriv", 69: "ReCo",
    70: "Flag Cal", 71: "Ca00", 72: "Ca01", 73: "Ca03", 74: "Ca04",
    75: "Ca06", 76: "Ca07", 77: "Ca08", 78: "Ca09", 79: "Ca10",
    80: "Ca11", 81: "Ca12", 82: "Ca13", 83: "Ca14", 84: "Ca15", 85: "R", 86: "ReCa",
    90: "Flag Ctrl", 91: "Cn00", 92: "Cn01", 93: "Cn02", 94: "Cn03", 95: "ReCn"
}

contenido = []
contenido.append("=" * 80)
contenido.append(f"PARÁMETROS DE CONFIGURACIÓN - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
contenido.append(f"Equipo S/N: {NUMERO_SERIE}")
contenido.append("=" * 80)
contenido.append("")
contenido.append("PLACAS DETECTADAS:")
contenido.append(f"  • L1 (Fase 1) - Nº Serie Placa: {sn_l1}")
contenido.append(f"  • L2 (Fase 2) - Nº Serie Placa: {sn_l2}")
contenido.append(f"  • L3 (Fase 3) - Nº Serie Placa: {sn_l3}")
contenido.append("=" * 80)
contenido.append("")

# Mostrar en 3 columnas
contenido.append(f"{'Reg':<4} {'Parámetro':<16} {'L1':>8} {'L2':>8} {'L3':>8}   {'Diferencia'}")
contenido.append(f"{'─'*4} {'─'*16} {'─'*8} {'─'*8} {'─'*8}   {'─'*12}")

def add_section(title, start, end):
    contenido.append(f"\n── {title} ──")
    for i in range(start, end):
        if i in REGS_CORTOS:
            v1 = placas_leidas[1][i] if i < len(placas_leidas[1]) else 0
            v2 = placas_leidas[2][i] if i < len(placas_leidas[2]) else 0
            v3 = placas_leidas[3][i] if i < len(placas_leidas[3]) else 0
            diff = "⚠️ DIFF" if not (v1 == v2 == v3) else ""
            contenido.append(f"{i:<4} {REGS_CORTOS[i]:<16} {v1:>8} {v2:>8} {v3:>8}   {diff}")

add_section("TIEMPO REAL", 0, 22)
add_section("ESTADO", 30, 35)
add_section("CONFIGURACIÓN", 40, 70)
add_section("CALIBRACIÓN", 70, 87)
add_section("CONTROL", 90, 96)

contenido.append("")
contenido.append("=" * 80)

texto = "\n".join(contenido)
print(texto)

# Enviar email
msg = MIMEMultipart('alternative')
msg['Subject'] = f"📋 Configuración Modbus - Equipo {NUMERO_SERIE} - Placas: {sn_l1}/{sn_l2}/{sn_l3} - {datetime.now().strftime('%Y-%m-%d %H:%M')}"
msg['From'] = SMTP_FROM
msg['To'] = SMTP_TO

text_part = MIMEText(texto, 'plain', 'utf-8')
msg.attach(text_part)

html_content = f"""
<html>
<head><style>
body {{ font-family: Arial, sans-serif; }}
pre {{ background-color: #f4f4f4; padding: 15px; border-radius: 5px; font-family: 'Courier New', monospace; font-size: 12px; }}
.header {{ background-color: #3498db; color: white; padding: 10px 20px; border-radius: 5px; }}
</style></head>
<body>
<div class="header">
<h2>📋 Configuración Modbus - Equipo {NUMERO_SERIE}</h2>
<p>Fecha: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
</div>
<pre>{texto}</pre>
</body>
</html>
"""
html_part = MIMEText(html_content, 'html', 'utf-8')
msg.attach(html_part)

try:
    server = smtplib.SMTP(SMTP_SERVER, SMTP_PORT)
    server.starttls()
    server.login(SMTP_USER, SMTP_PASSWORD)
    server.sendmail(SMTP_FROM, SMTP_TO.split(','), msg.as_string())
    server.quit()
    print(f"\n✅ Email enviado a: {SMTP_TO}")
except Exception as e:
    print(f"\n❌ Error enviando email: {e}")
EOFEMAIL
            
            echo ""
            echo "  🔄 Reiniciando servicios..."
            sudo systemctl start nodered
            docker start gesinne-rpi >/dev/null 2>&1 || true
            
            echo "  ✅ Listo"
            volver_menu
            ;;
        7)
            # Revisar espacio y logs
            echo ""
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Revisar espacio y logs"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
            # Espacio en disco
            echo "  📊 ESPACIO EN DISCO"
            echo "  ─────────────────────────────────────────────"
            df -h / | awk 'NR==1 {print "  " $0} NR==2 {print "  " $0}'
            echo ""
            
            # Uso por directorio
            echo "  📁 USO POR DIRECTORIO (top 10)"
            echo "  ─────────────────────────────────────────────"
            du -sh /var/log /var/cache /tmp /home/*/.node-red /var/lib/docker 2>/dev/null | sort -rh | head -10 | while read line; do
                echo "  $line"
            done
            echo ""
            
            # Logs más grandes
            echo "  📜 LOGS MÁS GRANDES"
            echo "  ─────────────────────────────────────────────"
            find /var/log -type f -name "*.log" -o -name "*.log.*" 2>/dev/null | xargs du -sh 2>/dev/null | sort -rh | head -10 | while read line; do
                echo "  $line"
            done
            echo ""
            
            # Journal
            JOURNAL_SIZE=$(journalctl --disk-usage 2>/dev/null | grep -oP '[0-9.]+[GMK]' | head -1)
            echo "  📰 JOURNAL SYSTEMD: ${JOURNAL_SIZE:-desconocido}"
            echo ""
            
            # Docker
            if command -v docker &> /dev/null; then
                echo "  🐳 DOCKER"
                echo "  ─────────────────────────────────────────────"
                docker system df 2>/dev/null | while read line; do
                    echo "  $line"
                done
                echo ""
            fi
            
            # Menú de limpieza
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ¿Qué quieres limpiar?"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  1) Limpiar journal systemd (vacuum 3 días)"
            echo "  2) Limpiar logs /var/log (rotar y comprimir)"
            echo "  3) Limpiar caché apt (apt clean)"
            echo "  4) Limpiar Docker (imágenes y contenedores sin usar)"
            echo "  5) Limpiar TODO (journal + logs + apt + docker)"
            echo "  6) Reducir logs permanentemente (conexión lenta)"
            echo "  0) No limpiar, volver al menú"
            echo ""
            read -p "  Opción [0-6]: " CLEAN_OPT
            
            case $CLEAN_OPT in
                1)
                    echo ""
                    echo "  🧹 Limpiando journal systemd..."
                    sudo journalctl --vacuum-time=3d
                    sudo journalctl --vacuum-size=100M
                    echo "  ✅ Journal limpiado"
                    ;;
                2)
                    echo ""
                    echo "  🧹 Limpiando logs en /var/log..."
                    # Rotar logs
                    sudo logrotate -f /etc/logrotate.conf 2>/dev/null || true
                    # Borrar logs antiguos (.gz, .1, .2, etc)
                    sudo find /var/log -type f -name "*.gz" -delete 2>/dev/null
                    sudo find /var/log -type f -name "*.1" -delete 2>/dev/null
                    sudo find /var/log -type f -name "*.2" -delete 2>/dev/null
                    sudo find /var/log -type f -name "*.[3-9]" -delete 2>/dev/null
                    sudo find /var/log -type f -name "*.old" -delete 2>/dev/null
                    # Vaciar logs activos grandes
                    sudo truncate -s 0 /var/log/syslog 2>/dev/null || true
                    sudo truncate -s 0 /var/log/messages 2>/dev/null || true
                    sudo truncate -s 0 /var/log/daemon.log 2>/dev/null || true
                    sudo truncate -s 0 /var/log/kern.log 2>/dev/null || true
                    echo "  ✅ Logs limpiados"
                    ;;
                3)
                    echo ""
                    echo "  🧹 Limpiando caché apt..."
                    sudo apt-get clean
                    sudo apt-get autoremove -y
                    echo "  ✅ Caché apt limpiada"
                    ;;
                4)
                    echo ""
                    echo "  🧹 Limpiando Docker..."
                    docker system prune -af 2>/dev/null || echo "  ⚠️ Docker no disponible"
                    echo "  ✅ Docker limpiado"
                    ;;
                5)
                    echo ""
                    echo "  🧹 Limpiando TODO..."
                    echo ""
                    echo "  → Journal systemd..."
                    sudo journalctl --vacuum-time=3d
                    sudo journalctl --vacuum-size=100M
                    echo ""
                    echo "  → Logs /var/log..."
                    sudo logrotate -f /etc/logrotate.conf 2>/dev/null || true
                    sudo find /var/log -type f -name "*.gz" -delete 2>/dev/null
                    sudo find /var/log -type f -name "*.1" -delete 2>/dev/null
                    sudo find /var/log -type f -name "*.2" -delete 2>/dev/null
                    sudo find /var/log -type f -name "*.[3-9]" -delete 2>/dev/null
                    sudo find /var/log -type f -name "*.old" -delete 2>/dev/null
                    sudo truncate -s 0 /var/log/syslog 2>/dev/null || true
                    sudo truncate -s 0 /var/log/messages 2>/dev/null || true
                    sudo truncate -s 0 /var/log/daemon.log 2>/dev/null || true
                    sudo truncate -s 0 /var/log/kern.log 2>/dev/null || true
                    echo ""
                    echo "  → Caché apt..."
                    sudo apt-get clean
                    sudo apt-get autoremove -y
                    echo ""
                    echo "  → Docker..."
                    docker system prune -af 2>/dev/null || echo "  ⚠️ Docker no disponible"
                    echo ""
                    echo "  ✅ Limpieza completa"
                    ;;
                6)
                    echo ""
                    echo "  ⚙️  Configurando reducción permanente de logs..."
                    echo ""
                    
                    # 1. Limitar journal a 50MB máximo
                    echo "  → Limitando journal systemd a 50MB..."
                    sudo mkdir -p /etc/systemd/journald.conf.d/
                    cat << 'EOFJOURNALD' | sudo tee /etc/systemd/journald.conf.d/size.conf > /dev/null
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
MaxRetentionSec=3day
EOFJOURNALD
                    sudo systemctl restart systemd-journald
                    
                    # 2. Configurar logrotate más agresivo
                    echo "  → Configurando rotación diaria de logs..."
                    cat << 'EOFLOGROTATE' | sudo tee /etc/logrotate.d/rpi-minimal > /dev/null
/var/log/syslog
/var/log/messages
/var/log/daemon.log
/var/log/kern.log
/var/log/auth.log
{
    rotate 2
    daily
    maxsize 10M
    missingok
    notifempty
    compress
    delaycompress
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOFLOGROTATE
                    
                    # 3. Reducir nivel de log de rsyslog
                    echo "  → Reduciendo nivel de logs rsyslog..."
                    if [ -f /etc/rsyslog.conf ]; then
                        # Comentar logs innecesarios
                        sudo sed -i 's/^\*\.=debug/#\*\.=debug/' /etc/rsyslog.conf
                        sudo sed -i 's/^\*\.=info/#\*\.=info/' /etc/rsyslog.conf
                        sudo systemctl restart rsyslog 2>/dev/null || true
                    fi
                    
                    # 4. Desactivar logs de kernel verbose
                    echo "  → Reduciendo logs del kernel..."
                    echo "kernel.printk = 3 3 3 3" | sudo tee /etc/sysctl.d/99-quiet-kernel.conf > /dev/null
                    sudo sysctl -p /etc/sysctl.d/99-quiet-kernel.conf 2>/dev/null || true
                    
                    # 5. Limpiar logs actuales
                    echo "  → Limpiando logs actuales..."
                    sudo journalctl --vacuum-size=50M
                    sudo find /var/log -type f -name "*.gz" -delete 2>/dev/null
                    sudo find /var/log -type f -name "*.[1-9]" -delete 2>/dev/null
                    sudo truncate -s 0 /var/log/syslog 2>/dev/null || true
                    sudo truncate -s 0 /var/log/daemon.log 2>/dev/null || true
                    
                    echo ""
                    echo "  ✅ Logs reducidos permanentemente:"
                    echo "     • Journal limitado a 50MB"
                    echo "     • Rotación diaria, máximo 2 archivos"
                    echo "     • Logs debug/info desactivados"
                    echo "     • Kernel en modo silencioso"
                    ;;
                *)
                    echo "  ❌ Cancelado"
                    ;;
            esac
            
            # Mostrar espacio después de limpiar
            if [ "$CLEAN_OPT" != "0" ] && [ -n "$CLEAN_OPT" ]; then
                echo ""
                echo "  📊 ESPACIO DESPUÉS DE LIMPIAR"
                echo "  ─────────────────────────────────────────────"
                df -h / | awk 'NR==1 {print "  " $0} NR==2 {print "  " $0}'
            fi
            
            volver_menu
            ;;
        8)
            # Gestionar paleta Node-RED
            echo ""
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Gestionar paleta Node-RED"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
            # Buscar directorio node_modules
            NODERED_DIR=""
            for d in /home/*/.node-red; do
                if [ -d "$d" ]; then
                    NODERED_DIR="$d"
                    break
                fi
            done
            
            if [ -z "$NODERED_DIR" ]; then
                echo "  ❌ No se encontró directorio .node-red"
                volver_menu
                continue
            fi
            
            MODULES_DIR="$NODERED_DIR/node_modules"
            
            echo "  📦 NODOS INSTALADOS"
            echo "  ─────────────────────────────────────────────"
            echo ""
            
            # Listar nodos node-red instalados con versiones
            if [ -d "$MODULES_DIR" ]; then
                cd "$MODULES_DIR"
                
                # Buscar paquetes node-red
                NODES_INFO=$(find . -maxdepth 2 -name "package.json" 2>/dev/null | while read pkg; do
                    DIR=$(dirname "$pkg")
                    NAME=$(python3 -c "import json; print(json.load(open('$pkg')).get('name', ''))" 2>/dev/null)
                    VERSION=$(python3 -c "import json; print(json.load(open('$pkg')).get('version', '?'))" 2>/dev/null)
                    if echo "$NAME" | grep -qE "^(node-red|@flowfuse|@node-red)"; then
                        echo "$NAME|$VERSION"
                    fi
                done | sort)
                
                if [ -n "$NODES_INFO" ]; then
                    echo "$NODES_INFO" | while IFS='|' read NAME VERSION; do
                        printf "  %-45s %s\n" "$NAME" "v$VERSION"
                    done
                else
                    echo "  No se encontraron nodos node-red"
                fi
                
                cd - > /dev/null
            else
                echo "  ❌ No existe directorio node_modules"
            fi
            
            echo ""
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ¿Qué quieres hacer?"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  1) Actualizar TODOS los nodos"
            echo "  2) Actualizar un nodo específico"
            echo "  3) Instalar un nodo nuevo"
            echo "  4) Desinstalar un nodo"
            echo "  0) Volver al menú"
            echo ""
            read -p "  Opción [0-4]: " PALETTE_OPT
            
            case $PALETTE_OPT in
                1)
                    echo ""
                    echo "  🔄 Actualizando todos los nodos..."
                    echo ""
                    cd "$NODERED_DIR"
                    
                    # Parar Node-RED
                    echo "  ⚠️  Parando Node-RED..."
                    sudo systemctl stop nodered
                    sleep 2
                    
                    # Actualizar todos los nodos node-red
                    npm update 2>&1 | while read line; do echo "  $line"; done
                    
                    echo ""
                    echo "  🔄 Reiniciando Node-RED..."
                    sudo systemctl start nodered
                    sleep 3
                    echo "  ✅ Nodos actualizados"
                    ;;
                2)
                    echo ""
                    read -p "  Nombre del nodo a actualizar: " NODE_NAME
                    if [ -n "$NODE_NAME" ]; then
                        echo ""
                        echo "  🔄 Actualizando $NODE_NAME..."
                        cd "$NODERED_DIR"
                        
                        sudo systemctl stop nodered
                        sleep 2
                        
                        npm update "$NODE_NAME" 2>&1 | while read line; do echo "  $line"; done
                        
                        sudo systemctl start nodered
                        sleep 3
                        echo "  ✅ $NODE_NAME actualizado"
                    fi
                    ;;
                3)
                    echo ""
                    echo "  Nodos comunes:"
                    echo "    - node-red-dashboard"
                    echo "    - @flowfuse/node-red-dashboard"
                    echo "    - node-red-contrib-ui-led"
                    echo "    - node-red-node-serialport"
                    echo ""
                    read -p "  Nombre del nodo a instalar: " NODE_NAME
                    if [ -n "$NODE_NAME" ]; then
                        echo ""
                        echo "  📦 Instalando $NODE_NAME..."
                        cd "$NODERED_DIR"
                        
                        sudo systemctl stop nodered
                        sleep 2
                        
                        npm install "$NODE_NAME" 2>&1 | while read line; do echo "  $line"; done
                        
                        sudo systemctl start nodered
                        sleep 3
                        echo "  ✅ $NODE_NAME instalado"
                    fi
                    ;;
                4)
                    echo ""
                    read -p "  Nombre del nodo a desinstalar: " NODE_NAME
                    if [ -n "$NODE_NAME" ]; then
                        echo ""
                        read -p "  ⚠️  ¿Seguro que quieres desinstalar $NODE_NAME? [s/N]: " CONFIRM
                        if [ "$CONFIRM" = "s" ] || [ "$CONFIRM" = "S" ]; then
                            echo ""
                            echo "  🗑️  Desinstalando $NODE_NAME..."
                            cd "$NODERED_DIR"
                            
                            sudo systemctl stop nodered
                            sleep 2
                            
                            npm uninstall "$NODE_NAME" 2>&1 | while read line; do echo "  $line"; done
                            
                            sudo systemctl start nodered
                            sleep 3
                            echo "  ✅ $NODE_NAME desinstalado"
                        else
                            echo "  ❌ Cancelado"
                        fi
                    fi
                    ;;
                *)
                    echo "  ❌ Cancelado"
                    ;;
            esac
            
            volver_menu
            ;;
        *)
            # Opción no válida, volver al menú
            ;;
    esac
done

# Solo pedir connection string si elige Azure (código legacy, no se usa con el bucle)
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
  gesinne-rpi:
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
# refresh 1764843038
