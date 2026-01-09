#!/bin/bash
#
# Script para configurar MQTT con TLS en Node-RED
# Uso: bash fix_mqtt_tls.sh
#
# Este script:
# 1. Configura el broker MQTT para usar mqtt.gesinne.cloud:8883 con TLS
# 2. Crea el nodo TLS config si no existe
# 3. Regenera las credenciales MQTT
# 4. Reinicia Node-RED
#

set -e

NODERED_DIR="/home/gesinne/.node-red"
MQTT_USER="gesinne"
MQTT_PASS="wrljEVeciudi0paswecuhl"
CRED_SECRET="Gesinne20."

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Configurar MQTT con TLS para Node-RED"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Verificar directorio
if [ ! -d "$NODERED_DIR" ]; then
    echo "  [X] No se encontró directorio Node-RED: $NODERED_DIR"
    exit 1
fi

cd "$NODERED_DIR"

# Backup
echo "  [~] Creando backup..."
cp flows.json flows.json.bak.$(date +%Y%m%d_%H%M%S)
cp flows_cred.json flows_cred.json.bak.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true

# Actualizar flows.json con TLS
echo "  [~] Actualizando configuración MQTT con TLS..."
python3 << 'PYTHON_SCRIPT'
import json

with open('flows.json', 'r') as f:
    flows = json.load(f)

# Crear nodo TLS config si no existe
tls_id = "tls_config_mqtt_8883"
tls_exists = False
mqtt_broker_id = None

for node in flows:
    if node.get('type') == 'tls-config':
        tls_exists = True
        tls_id = node.get('id')
    if node.get('type') == 'mqtt-broker':
        mqtt_broker_id = node.get('id')

if not tls_exists:
    tls_node = {
        "id": tls_id,
        "type": "tls-config",
        "name": "MQTT TLS",
        "cert": "",
        "key": "",
        "ca": "",
        "certname": "",
        "keyname": "",
        "caname": "",
        "servername": "",
        "verifyservercert": False,
        "alpnprotocol": ""
    }
    flows.append(tls_node)
    print("  [OK] Nodo TLS creado")
else:
    print("  [OK] Nodo TLS ya existe")

# Actualizar broker MQTT
for node in flows:
    if node.get('type') == 'mqtt-broker':
        node['broker'] = 'mqtt.gesinne.cloud'
        node['port'] = '8883'
        node['usetls'] = True
        node['tls'] = tls_id
        print(f"  [OK] Broker actualizado: mqtt.gesinne.cloud:8883 con TLS")

with open('flows.json', 'w') as f:
    json.dump(flows, f, indent=2)

# Guardar IDs para credenciales
with open('/tmp/mqtt_ids.txt', 'w') as f:
    f.write(f"{mqtt_broker_id}\n")

print("  [OK] Configuración guardada")
PYTHON_SCRIPT

# Obtener IDs
MQTT_ID=$(head -1 /tmp/mqtt_ids.txt)

# Obtener ID de chronos
CHRONOS_ID=$(python3 -c "
import json
with open('flows.json') as f:
    flows = json.load(f)
for node in flows:
    if node.get('type') == 'chronos-config':
        print(node.get('id'))
        break
" 2>/dev/null || echo "")

echo "  [~] Regenerando credenciales..."
echo "      MQTT ID: $MQTT_ID"
echo "      Chronos ID: $CHRONOS_ID"

# Generar credenciales
if [ -n "$CHRONOS_ID" ]; then
    sudo node -e "
const crypto = require('crypto');
const fs = require('fs');

const key = crypto.createHash('sha256').update('$CRED_SECRET').digest();

const creds = {
    '$MQTT_ID': {
        user: '$MQTT_USER',
        password: '$MQTT_PASS'
    },
    '$CHRONOS_ID': {
        latitude: '43.53099',
        longitude: '-5.71694'
    }
};

const iv = crypto.randomBytes(16);
const cipher = crypto.createCipheriv('aes-256-ctr', key, iv);
let encrypted = cipher.update(JSON.stringify(creds), 'utf8', 'base64');
encrypted += cipher.final('base64');

const result = { '\$': iv.toString('hex') + encrypted };
fs.writeFileSync('flows_cred.json', JSON.stringify(result, null, 4));
console.log('  [OK] Credenciales generadas (MQTT + Chronos)');
"
else
    sudo node -e "
const crypto = require('crypto');
const fs = require('fs');

const key = crypto.createHash('sha256').update('$CRED_SECRET').digest();

const creds = {
    '$MQTT_ID': {
        user: '$MQTT_USER',
        password: '$MQTT_PASS'
    }
};

const iv = crypto.randomBytes(16);
const cipher = crypto.createCipheriv('aes-256-ctr', key, iv);
let encrypted = cipher.update(JSON.stringify(creds), 'utf8', 'base64');
encrypted += cipher.final('base64');

const result = { '\$': iv.toString('hex') + encrypted };
fs.writeFileSync('flows_cred.json', JSON.stringify(result, null, 4));
console.log('  [OK] Credenciales generadas (MQTT)');
"
fi

sudo chown gesinne:gesinne flows_cred.json
rm -f /tmp/mqtt_ids.txt

echo "  [~] Reiniciando Node-RED..."
sudo systemctl restart nodered
sleep 5

echo ""
echo "  [~] Verificando conexión MQTT..."
sudo journalctl -u nodered -n 10 --no-pager | grep -i "mqtt" || echo "  [i] Sin mensajes MQTT en logs"

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [OK] Completado"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Configuración aplicada:"
echo "    - Broker: mqtt.gesinne.cloud"
echo "    - Puerto: 8883 (SSL/TLS)"
echo "    - Usuario: gesinne"
echo ""
echo "  Verifica en Node-RED que el broker muestre 'connected'"
echo ""
