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

if [ -f "$OVERRIDE_FILE" ]; then
    echo "  ✅ Instalación existente detectada"
    echo ""
    echo "  ¿Qué deseas hacer?"
    echo ""
    echo "  1) Actualizar software (mantener configuración)"
    echo "  2) Reconfigurar (nueva connection string)"
    echo "  3) Salir"
    echo ""
    read -p "  Opción [1/2/3]: " OPTION
    
    case $OPTION in
        1)
            echo ""
            echo "  📥 Actualizando..."
            cd "$INSTALL_DIR"
            git pull
            docker-compose down 2>/dev/null || true
            docker-compose up -d --build
            echo ""
            echo "  ✅ Actualización completada"
            echo ""
            docker-compose logs --tail=10
            exit 0
            ;;
        2)
            # Continuar con reconfiguración
            ;;
        *)
            echo ""
            echo "  👋 Saliendo"
            exit 0
            ;;
    esac
fi

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PASO 1: Connection String"
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

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PASO 2: Configurar Node-RED"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Buscar archivo de flows de Node-RED
USER_HOME="/home/$(logname 2>/dev/null || echo 'pi')"
FLOWS_FILE=""
for f in "$USER_HOME/.node-red/flows.json" "/home/pi/.node-red/flows.json" "/home/gesinne/.node-red/flows.json"; do
    if [ -f "$f" ]; then
        FLOWS_FILE="$f"
        break
    fi
done

if [ -n "$FLOWS_FILE" ]; then
    # Extraer configuración actual del broker MQTT
    CURRENT_BROKER=$(grep -o '"broker"[[:space:]]*:[[:space:]]*"[^"]*"' "$FLOWS_FILE" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    
    # Buscar el nodo mqtt-broker y su configuración
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

    echo "  📡 Node-RED detectado"
    echo "  📁 Archivo: $FLOWS_FILE"
    echo "  🔗 Broker actual: $BROKER_HOST"
    echo ""
    
    if [ "$BROKER_HOST" != "localhost" ] && [ "$BROKER_HOST" != "127.0.0.1" ]; then
        echo "  ⚠️  El broker NO apunta a localhost"
        echo ""
        read -p "  ¿Cambiar broker a localhost? [S/n]: " CHANGE_BROKER
        
        if [ "$CHANGE_BROKER" != "n" ] && [ "$CHANGE_BROKER" != "N" ]; then
            # Hacer backup
            cp "$FLOWS_FILE" "${FLOWS_FILE}.backup.$(date +%Y%m%d%H%M%S)"
            
            # Cambiar broker a localhost usando Python
            python3 -c "
import json
with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)
for node in flows:
    if node.get('type') == 'mqtt-broker':
        node['broker'] = 'localhost'
        node['port'] = '1883'
        if 'usetls' in node:
            node['usetls'] = False
        if 'credentials' in node:
            del node['credentials']
with open('$FLOWS_FILE', 'w') as f:
    json.dump(flows, f, indent=4)
print('OK')
" 2>/dev/null
            
            echo "  ✅ Broker cambiado a localhost:1883"
            echo ""
            echo "  ⚠️  Reiniciando Node-RED..."
            systemctl restart nodered 2>/dev/null || node-red-restart 2>/dev/null || true
            sleep 2
            echo "  ✅ Node-RED reiniciado"
        fi
    else
        echo "  ✅ Broker ya configurado en localhost"
    fi
else
    echo "  ⚠️  Node-RED no detectado (no se encontró flows.json)"
    echo "     Configura manualmente el broker MQTT a localhost:1883"
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
