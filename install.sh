#!/bin/bash
#
# Instalador automático del puente MQTT → Azure IoT Hub
# Uso: curl -sSL https://raw.githubusercontent.com/Gesinne/rpi-azure-bridge/main/install.sh | sudo bash
#

set -e

echo "=============================================="
echo "  Instalador MQTT → Azure IoT Hub Bridge"
echo "=============================================="
echo ""

# Verificar que se ejecuta como root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Este script debe ejecutarse como root (sudo)"
    exit 1
fi

# Pedir connection string si no se proporciona
if [ -z "$AZURE_CONNECTION_STRING" ]; then
    echo "📝 Introduce la Connection String del dispositivo Azure IoT Hub:"
    echo "   (Formato: HostName=xxx.azure-devices.net;DeviceId=xxx;SharedAccessKey=xxx)"
    echo ""
    read -p "Connection String: " AZURE_CONNECTION_STRING
    
    if [ -z "$AZURE_CONNECTION_STRING" ]; then
        echo "❌ Connection string vacía. Abortando."
        exit 1
    fi
fi

# Validar formato básico
if [[ ! "$AZURE_CONNECTION_STRING" =~ ^HostName=.*DeviceId=.*SharedAccessKey= ]]; then
    echo "❌ Formato de connection string inválido"
    exit 1
fi

echo ""
echo "🔧 Instalando Docker..."

# Instalar Docker si no existe
if ! command -v docker &> /dev/null; then
    apt-get update
    apt-get install -y docker.io docker-compose
    systemctl start docker
    systemctl enable docker
    echo "✅ Docker instalado"
else
    echo "✅ Docker ya instalado"
fi

# Instalar docker-compose si no existe
if ! command -v docker-compose &> /dev/null; then
    apt-get install -y docker-compose
    echo "✅ Docker Compose instalado"
fi

echo ""
echo "📥 Descargando puente MQTT → Azure..."

# Clonar o actualizar repositorio
INSTALL_DIR="/home/$(logname 2>/dev/null || echo 'pi')/rpi-azure-bridge"

if [ -d "$INSTALL_DIR" ]; then
    cd "$INSTALL_DIR"
    git pull
    echo "✅ Repositorio actualizado"
else
    git clone https://github.com/Gesinne/rpi-azure-bridge.git "$INSTALL_DIR"
    echo "✅ Repositorio clonado"
fi

cd "$INSTALL_DIR"

echo ""
echo "⚙️ Configurando connection string..."

# Crear docker-compose.override.yml con la connection string
cat > docker-compose.override.yml << EOF
services:
  mqtt-to-azure:
    environment:
      - AZURE_CONNECTION_STRING=${AZURE_CONNECTION_STRING}
EOF

chmod 600 docker-compose.override.yml
echo "✅ Configuración guardada"

echo ""
echo "🚀 Iniciando servicio..."

# Parar contenedor anterior si existe
docker-compose down 2>/dev/null || true

# Construir e iniciar
docker-compose up -d --build

echo ""
echo "=============================================="
echo "  ✅ Instalación completada"
echo "=============================================="
echo ""
echo "📍 Directorio: $INSTALL_DIR"
echo "🔍 Ver logs:   cd $INSTALL_DIR && sudo docker-compose logs -f"
echo "🏥 Healthcheck: curl http://localhost:8080/health"
echo ""
echo "⚡ El servicio se iniciará automáticamente al reiniciar"
echo ""

# Mostrar logs iniciales
echo "📋 Logs iniciales:"
echo "---"
sleep 3
docker-compose logs --tail=20
