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
    echo "  6) Salir"
    echo ""
    read -p "  Opción [1-6]: " OPTION
    
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
            match = re.search(r'Version[^0-9]*([0-9]{4}_[0-9]{2}_[0-9]{2}[^\\\"\\n]*)', func)
            if match:
                print(f'  📋 Versión Flow: {match.group(1).strip()}')
                version_found = True
                break
    
    if not version_found:
        # Buscar en todo el archivo
        with open('$flowfile') as file:
            content = file.read()
        match = re.search(r'Version[^0-9]*([0-9]{4}_[0-9]{2}_[0-9]{2}[^\\\"\\n]*)', content)
        if match:
            print(f'  📋 Versión Flow: {match.group(1).strip()}')
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
            
            NODERED_REPO="https://raw.githubusercontent.com/Gesinne/NODERED/main"
            
            # Obtener lista de versiones disponibles (archivos .json)
            echo "  📥 Obteniendo versiones disponibles..."
            VERSIONS=$(curl -s "https://api.github.com/repos/Gesinne/NODERED/contents" | python3 -c "
import sys, json
try:
    items = json.load(sys.stdin)
    for item in items:
        name = item.get('name', '')
        if name.endswith('.json') and item.get('type') == 'file':
            print(name)
except:
    pass
" 2>/dev/null)
            
            echo ""
            echo "  Versiones disponibles:"
            echo ""
            
            i=1
            declare -a VERSION_ARRAY
            for v in $VERSIONS; do
                echo "  $i) $v"
                VERSION_ARRAY[$i]="$v"
                i=$((i+1))
            done
            
            echo ""
            read -p "  Selecciona versión [1-$((i-1))]: " VERSION_CHOICE
            
            # Determinar URL del flow
            VERSION_NAME="${VERSION_ARRAY[$VERSION_CHOICE]}"
            if [ -n "$VERSION_NAME" ]; then
                FLOW_URL="$NODERED_REPO/$VERSION_NAME"
            else
                FLOW_URL=""
            fi
            
            if [ -z "$FLOW_URL" ]; then
                echo "  ❌ Opción no válida"
                exit 1
            fi
            
            echo ""
            echo "  📥 Descargando $VERSION_NAME..."
            
            # Buscar directorio Node-RED
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
            
            # Backup del flow actual
            BACKUP_FILE="$NODERED_DIR/flows.json.backup.$(date +%Y%m%d%H%M%S)"
            cp "$NODERED_DIR/flows.json" "$BACKUP_FILE"
            echo "  💾 Backup creado: $BACKUP_FILE"
            
            # Descargar nuevo flow
            if curl -sSL "$FLOW_URL" -o /tmp/new_flows.json; then
                # Verificar que es JSON válido
                if python3 -c "import json; json.load(open('/tmp/new_flows.json'))" 2>/dev/null; then
                    cp /tmp/new_flows.json "$NODERED_DIR/flows.json"
                    echo "  ✅ Flow instalado: $VERSION_NAME"
                    echo ""
                    echo "  🔄 Reiniciando Node-RED..."
                    sudo systemctl restart nodered
                    sleep 3
                    echo "  ✅ Node-RED reiniciado"
                    echo ""
                    echo "  ⚠️  Recuerda configurar equipo_config.json con los datos del equipo"
                else
                    echo "  ❌ Error: El archivo descargado no es JSON válido"
                    exit 1
                fi
            else
                echo "  ❌ Error descargando flow"
                exit 1
            fi
            
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
