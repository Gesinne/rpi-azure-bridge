#!/bin/bash
#
# Script para actualizar Flow de Node-RED
# Extraído de install.sh para mejor mantenibilidad
#

set -e

# Colores y formato
echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Actualizar Flow Node-RED"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

CACHE_DIR="/opt/nodered-flows-cache"
CREDS_FILE="/opt/nodered-flows-cache/.git_credentials"

# Función para añadir credenciales de chronos-config
crear_chronos_credentials() {
    NODERED_DIR="$1"
    CHRONOS_ID="$2"
    LAT="$3"
    LON="$4"
    CRED_SECRET="Gesinne20."
    
    cd "$NODERED_DIR"
    sudo node -e "
const crypto = require('crypto');
const fs = require('fs');

const key = crypto.createHash('sha256').update('$CRED_SECRET').digest();

// Leer credenciales existentes si hay
let existingCreds = {};
try {
    const credFile = fs.readFileSync('flows_cred.json', 'utf8');
    const credData = JSON.parse(credFile);
    if (credData['\$']) {
        const encData = credData['\$'];
        const iv = Buffer.from(encData.substring(0, 32), 'hex');
        const encrypted = encData.substring(32);
        const decipher = crypto.createDecipheriv('aes-256-ctr', key, iv);
        let decrypted = decipher.update(encrypted, 'base64', 'utf8');
        decrypted += decipher.final('utf8');
        existingCreds = JSON.parse(decrypted);
    }
} catch (e) {
    // No hay archivo o error al leer, empezar vacío
}

// Añadir/actualizar credenciales de chronos
existingCreds['$CHRONOS_ID'] = {
    latitude: '$LAT',
    longitude: '$LON'
};

// Encriptar y guardar
const iv = crypto.randomBytes(16);
const cipher = crypto.createCipheriv('aes-256-ctr', key, iv);
let encrypted = cipher.update(JSON.stringify(existingCreds), 'utf8', 'base64');
encrypted += cipher.final('base64');

const result = {};
result['\$'] = iv.toString('hex') + encrypted;

fs.writeFileSync('flows_cred.json', JSON.stringify(result, null, 4));
" 2>/dev/null
    
    # Corregir propietario del archivo
    sudo chown gesinne:gesinne "$NODERED_DIR/flows_cred.json" 2>/dev/null
}

# Usuario fijo de GitHub
GIT_USER="Gesinne"

# Verificar si hay token guardado
if [ -f "$CREDS_FILE" ]; then
    source "$CREDS_FILE"
    echo "  [K] Usuario: $GIT_USER"
    if [ -n "$GIT_TOKEN" ]; then
        echo "  [K] Token guardado encontrado"
        echo ""
        read -p "  ¿Usar este token? [S/n]: " USE_SAVED
        if [ "$USE_SAVED" = "n" ] || [ "$USE_SAVED" = "N" ]; then
            GIT_TOKEN=""
        fi
    fi
fi

# Solicitar token si no hay guardado
if [ -z "$GIT_TOKEN" ]; then
    echo "  [K] Credenciales de GitHub (repo privado)"
    echo "  [K] Usuario: $GIT_USER"
    echo ""
    read -s -p "  Token/Contraseña: " GIT_TOKEN
    echo ""
    
    if [ -z "$GIT_TOKEN" ]; then
        echo "  [X] Token es requerido"
        exit 1
    fi
    
    # Guardar credenciales para próximas veces
    sudo mkdir -p "$CACHE_DIR" 2>/dev/null
    echo "GIT_USER=\"$GIT_USER\"" | sudo tee "$CREDS_FILE" > /dev/null
    echo "GIT_TOKEN=\"$GIT_TOKEN\"" | sudo tee -a "$CREDS_FILE" > /dev/null
    sudo chmod 600 "$CREDS_FILE"
    echo "  [D] Token guardado"
fi

NODERED_REPO="https://${GIT_USER}:${GIT_TOKEN}@github.com/Gesinne/NODERED.git"

# Usar caché o clonar
echo ""
echo "  [v] Obteniendo versiones disponibles..."

# Función para clonar/actualizar repo
clone_repo() {
    # Preservar credenciales antes de borrar
    local saved_creds=""
    if [ -f "$CREDS_FILE" ]; then
        saved_creds=$(cat "$CREDS_FILE")
    fi
    
    rm -rf "$CACHE_DIR"
    sudo mkdir -p "$CACHE_DIR" 2>/dev/null
    sudo chown $(whoami) "$CACHE_DIR" 2>/dev/null
    
    # Restaurar credenciales
    if [ -n "$saved_creds" ]; then
        echo "$saved_creds" | sudo tee "$CREDS_FILE" > /dev/null
        sudo chmod 600 "$CREDS_FILE"
    fi
    
    git clone -q --depth 1 "$NODERED_REPO" "$CACHE_DIR" 2>/dev/null
}

if [ -d "$CACHE_DIR/.git" ]; then
    # Ya existe, actualizar
    cd "$CACHE_DIR"
    git remote set-url origin "$NODERED_REPO" 2>/dev/null
    if ! git pull -q 2>/dev/null; then
        echo "  [!]  Error actualizando, re-clonando..."
        if ! clone_repo; then
            echo "  [X] Token inválido. Borrando y pidiendo nuevo..."
            sudo rm -f "$CREDS_FILE"
            rm -rf "$CACHE_DIR"
            echo ""
            echo "  [K] Usuario: $GIT_USER"
            read -s -p "  Nuevo Token/Contraseña: " GIT_TOKEN
            echo ""
            NODERED_REPO="https://${GIT_USER}:${GIT_TOKEN}@github.com/Gesinne/NODERED.git"
            if ! clone_repo; then
                echo "  [X] Error: credenciales incorrectas"
                exit 1
            fi
            # Guardar nuevas credenciales
            sudo mkdir -p "$CACHE_DIR" 2>/dev/null
            echo "GIT_USER=\"$GIT_USER\"" | sudo tee "$CREDS_FILE" > /dev/null
            echo "GIT_TOKEN=\"$GIT_TOKEN\"" | sudo tee -a "$CREDS_FILE" > /dev/null
            sudo chmod 600 "$CREDS_FILE"
            echo "  [D] Nuevas credenciales guardadas"
        fi
    fi
else
    # Primera vez, clonar
    if ! clone_repo; then
        echo "  [X] Token inválido. Pidiendo nuevo..."
        sudo rm -f "$CREDS_FILE"
        echo ""
        echo "  [K] Usuario: $GIT_USER"
        read -s -p "  Nuevo Token/Contraseña: " GIT_TOKEN
        echo ""
        NODERED_REPO="https://${GIT_USER}:${GIT_TOKEN}@github.com/Gesinne/NODERED.git"
        if ! clone_repo; then
            echo "  [X] Error: credenciales incorrectas"
            exit 1
        fi
        # Guardar nuevas credenciales
        sudo mkdir -p "$CACHE_DIR" 2>/dev/null
        echo "GIT_USER=\"$GIT_USER\"" | sudo tee "$CREDS_FILE" > /dev/null
        echo "GIT_TOKEN=\"$GIT_TOKEN\"" | sudo tee -a "$CREDS_FILE" > /dev/null
        sudo chmod 600 "$CREDS_FILE"
        echo "  [D] Nuevas credenciales guardadas"
    fi
fi

TEMP_DIR="$CACHE_DIR"

# Obtener versión actual instalada
CURRENT_VERSION=""
for flowfile in /home/*/.node-red/flows.json; do
    if [ -f "$flowfile" ]; then
        CURRENT_VERSION=$(python3 -c "
import re
try:
    with open('$flowfile') as f:
        content = f.read()
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

# Verificar paquetes instalados
HAS_FLOWFUSE=$([ -d "$NODERED_MODULES/@flowfuse/node-red-dashboard" ] && echo "yes" || echo "no")
HAS_CLASSIC=$([ -d "$NODERED_MODULES/node-red-dashboard" ] && echo "yes" || echo "no")

if [ "$HAS_FLOWFUSE" = "yes" ]; then
    echo "  [#] Dashboard actual: FlowFuse (dbrd2)"
elif [ "$HAS_CLASSIC" = "yes" ]; then
    echo "  [#] Dashboard actual: Clásico"
else
    echo "  [#] Dashboard actual: Ninguno detectado"
fi

# Listar archivos .json
VERSIONS=$(ls "$TEMP_DIR"/*.json 2>/dev/null | xargs -n1 basename | grep -E '^[0-9]{8}' | sort -r)

if [ -z "$VERSIONS" ]; then
    VERSIONS=$(ls "$TEMP_DIR"/*.json 2>/dev/null | xargs -n1 basename | sort -r)
fi

if [ -z "$VERSIONS" ]; then
    echo "  [X] No se encontraron archivos .json en el repositorio"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo ""
if [ -n "$CURRENT_VERSION" ]; then
    echo "  [i] Versión actual instalada: $CURRENT_VERSION"
fi
echo ""
echo "  Últimas 5 versiones disponibles:"
echo ""

i=1
declare -a VERSION_ARRAY
for v in $VERSIONS; do
    FILE_DATE=$(echo "$v" | grep -oE '^[0-9]{8}' || echo "00000000")
    
    if [ "$FILE_DATE" = "$CURRENT_VERSION" ]; then
        echo "  $i) $v (actual)"
    else
        echo "  $i) $v"
    fi
    VERSION_ARRAY[$i]="$v"
    i=$((i+1))
    
    if [ $i -gt 5 ]; then
        break
    fi
done

if [ $i -eq 1 ]; then
    echo "  [X] No hay versiones disponibles"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo ""
read -p "  Selecciona versión [1-$((i-1))]: " VERSION_CHOICE

VERSION_NAME="${VERSION_ARRAY[$VERSION_CHOICE]}"
if [ -n "$VERSION_NAME" ] && [ -f "$TEMP_DIR/$VERSION_NAME" ]; then
    FLOW_FILE="$TEMP_DIR/$VERSION_NAME"
else
    FLOW_FILE=""
fi

if [ -z "$FLOW_FILE" ]; then
    echo "  [X] Opción no válida"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Detectar si el flow necesita FlowFuse o Clásico
NEEDS_FLOWFUSE="no"
if grep -q '"type":\s*"ui-' "$FLOW_FILE" 2>/dev/null; then
    NEEDS_FLOWFUSE="yes"
    echo "  [#] Flow detectado: FlowFuse Dashboard"
else
    echo "  [#] Flow detectado: Dashboard Clásico"
fi

# Verificar si necesita cambiar el dashboard
cd "$NODERED_HOME"

# Limpiar dashboards anteriores
echo ""
echo "  [C] Limpiando dashboards anteriores..."
npm uninstall node-red-dashboard 2>/dev/null || true
npm uninstall @flowfuse/node-red-dashboard 2>/dev/null || true
npm uninstall @flowfuse/node-red-dashboard-2-ui-led 2>/dev/null || true

KIOSK_SCRIPT="/home/$(logname 2>/dev/null || echo $SUDO_USER)/kiosk.sh"

if [ "$NEEDS_FLOWFUSE" = "yes" ]; then
    echo "  [P] Instalando FlowFuse Dashboard (puede tardar)..."
    npm install @flowfuse/node-red-dashboard @flowfuse/node-red-dashboard-2-ui-led --save
    if [ $? -eq 0 ]; then
        echo "  [OK] FlowFuse Dashboard instalado"
    else
        echo "  [X] Error instalando FlowFuse Dashboard"
        exit 1
    fi
    if [ -f "$KIOSK_SCRIPT" ]; then
        sed -i 's|http://localhost:1880/ui|http://localhost:1880/dashboard|g' "$KIOSK_SCRIPT"
        echo "  [S]  Kiosko actualizado a /dashboard"
    fi
else
    echo "  [P] Instalando Dashboard Clásico (puede tardar)..."
    npm install node-red-dashboard --save
    if [ $? -eq 0 ]; then
        echo "  [OK] Dashboard Clásico instalado"
    else
        echo "  [X] Error instalando Dashboard Clásico"
        exit 1
    fi
    if [ -f "$KIOSK_SCRIPT" ]; then
        sed -i 's|http://localhost:1880/dashboard|http://localhost:1880/ui|g' "$KIOSK_SCRIPT"
        echo "  [S]  Kiosko actualizado a /ui"
    fi
fi

echo ""
echo "  [v] Instalando $VERSION_NAME..."

NODERED_DIR="$NODERED_HOME"

if [ -z "$NODERED_DIR" ]; then
    echo "  [X] No se encontró directorio Node-RED"
    exit 1
fi

# Backup del flow actual
BACKUP_FILE="$NODERED_DIR/flows.json.backup.$(date +%Y%m%d%H%M%S).${VERSION_NAME%.json}"
cp "$NODERED_DIR/flows.json" "$BACKUP_FILE"
echo "  [D] Backup creado: $BACKUP_FILE"

# Guardar configuración MQTT, maxQueue y chronos actual
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
        if node.get('type') == 'chronos-config':
            config['chronos'] = {
                'name': node.get('name', 'Por defecto'),
                'latitude': node.get('latitude', ''),
                'longitude': node.get('longitude', ''),
                'timezone': node.get('timezone', 'Europe/Madrid')
            }
    print(json.dumps(config))
except:
    pass
" 2>/dev/null)

# Verificar que es JSON válido e instalar
if python3 -c "import json; json.load(open('$FLOW_FILE'))" 2>/dev/null; then
    cp "$FLOW_FILE" "$NODERED_DIR/flows.json"
    
    # Restaurar configuración MQTT, maxQueue y chronos
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
    if node.get('type') == 'chronos-config' and 'chronos' in config:
        node['name'] = config['chronos']['name']
        node['latitude'] = config['chronos']['latitude']
        node['longitude'] = config['chronos']['longitude']
        node['timezone'] = config['chronos']['timezone']
with open('$NODERED_DIR/flows.json', 'w') as f:
    json.dump(flows, f, indent=4)
" 2>/dev/null
        echo "  [OK] Flow instalado: $VERSION_NAME"
        echo "  [>] Configuración preservada: MQTT + maxQueue + chronos"
    else
        echo "  [OK] Flow instalado: $VERSION_NAME"
    fi
    
    # Copiar carpeta Logo si existe
    USER_HOME_DIR=$(dirname "$NODERED_DIR")
    if [ -d "$TEMP_DIR/Logo" ]; then
        echo "  [F] Copiando carpeta Logo..."
        cp -r "$TEMP_DIR/Logo" "$USER_HOME_DIR/"
        chown -R $(basename "$USER_HOME_DIR"):$(basename "$USER_HOME_DIR") "$USER_HOME_DIR/Logo" 2>/dev/null
        echo "  [OK] Carpeta Logo copiada a $USER_HOME_DIR/Logo"
        
        # Configurar httpStatic en settings.js
        SETTINGS_FILE="$NODERED_DIR/settings.js"
        if [ -f "$SETTINGS_FILE" ]; then
            if ! grep -q "httpStatic:" "$SETTINGS_FILE"; then
                sed -i "/module.exports\s*=\s*{/a\\    httpStatic: '$USER_HOME_DIR/Logo/'," "$SETTINGS_FILE"
                echo "  [OK] httpStatic configurado en settings.js"
            else
                echo "  [i]  httpStatic ya está configurado"
            fi
        fi
    fi
    
    # Configurar chronos-config con valores por defecto si está vacío
    CHRONOS_CONFIGURED=$(python3 -c "
import json
changed = False
with open('$NODERED_DIR/flows.json', 'r') as f:
    flows = json.load(f)
for node in flows:
    if node.get('type') == 'chronos-config':
        tz = node.get('timezone', '')
        if not tz or '/' not in str(tz):
            node['timezone'] = 'Europe/Madrid'
            node['timezoneType'] = 'str'
            changed = True
        lat = node.get('latitude', '')
        try:
            float(lat) if lat else None
            if not lat:
                raise ValueError()
        except:
            node['latitude'] = '43.53099'
            node['latitudeType'] = 'num'
            changed = True
        lon = node.get('longitude', '')
        try:
            float(lon) if lon else None
            if not lon:
                raise ValueError()
        except:
            node['longitude'] = '-5.71694'
            node['longitudeType'] = 'num'
            changed = True
        if node.get('latitudeType') != 'num':
            node['latitudeType'] = 'num'
            changed = True
        if node.get('longitudeType') != 'num':
            node['longitudeType'] = 'num'
            changed = True
        if node.get('timezoneType') != 'str':
            node['timezoneType'] = 'str'
            changed = True
if changed:
    with open('$NODERED_DIR/flows.json', 'w') as f:
        json.dump(flows, f, indent=4)
    print('configured')
" 2>/dev/null)
    
    if [ "$CHRONOS_CONFIGURED" = "configured" ]; then
        echo "  [T] Chronos: configurado con valores por defecto (Europe/Madrid)"
    fi
    
    echo ""
    echo "  [~] Parando Node-RED..."
    sudo systemctl stop nodered
    sleep 2
    
    # Añadir credenciales de chronos
    CHRONOS_CREDS=$(python3 -c "
import json
with open('$NODERED_DIR/flows.json', 'r') as f:
    flows = json.load(f)
for node in flows:
    if node.get('type') == 'chronos-config':
        cid = node.get('id', '')
        lat = node.get('latitude', '43.53099')
        lon = node.get('longitude', '-5.71694')
        print(f'{cid}|{lat}|{lon}')
        break
" 2>/dev/null)
    
    if [ -n "$CHRONOS_CREDS" ]; then
        CHRONOS_ID=$(echo "$CHRONOS_CREDS" | cut -d'|' -f1)
        CHRONOS_LAT=$(echo "$CHRONOS_CREDS" | cut -d'|' -f2)
        CHRONOS_LON=$(echo "$CHRONOS_CREDS" | cut -d'|' -f3)
        crear_chronos_credentials "$NODERED_DIR" "$CHRONOS_ID" "$CHRONOS_LAT" "$CHRONOS_LON"
        echo "  [OK] Credenciales chronos actualizadas"
    fi
    
    read -p "  ¿Iniciar Node-RED ahora? [y/N]: " CONFIRMAR_START
    if [[ "$CONFIRMAR_START" =~ ^[Yy]$ ]]; then
        echo "  [~] Iniciando Node-RED..."
        sudo systemctl start nodered
        sleep 5
        echo "  [OK] Node-RED reiniciado"
        
        # Reiniciar kiosko si existe
        if systemctl list-unit-files kiosk.service &>/dev/null; then
            echo ""
            echo "  [~] Iniciando modo kiosko..."
            sudo systemctl restart kiosk.service
            sleep 2
            echo "  [OK] Kiosko iniciado"
        fi
    else
        echo "  [!] Node-RED NO iniciado. Recuerda iniciarlo manualmente:"
        echo "      sudo systemctl start nodered"
    fi
else
    echo "  [X] Error: El archivo no es JSON válido"
    exit 1
fi

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [OK] Actualización completada"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
