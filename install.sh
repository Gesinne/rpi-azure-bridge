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

# Función de limpieza al salir (interrupción, error, etc.)
cleanup_on_exit() {
    echo ""
    echo "  [~] Ajustando permisos de Node-RED..."
    for d in /home/*/.node-red/node_modules; do
        if [ -d "$d" ]; then
            OWNER=$(stat -c '%U:%G' "$(dirname "$d")" 2>/dev/null)
            sudo chown -R "$OWNER" "$d" 2>/dev/null || true
        fi
    done
    echo "  [OK] Permisos ajustados"
}

# Capturar señales de interrupción (Ctrl+C, cierre terminal, etc.)
trap cleanup_on_exit EXIT

# Si se ejecuta desde curl/pipe, descargar y ejecutar localmente
if [ ! -t 0 ] && [ -z "$GESINNE_DOWNLOADED" ]; then
    export GESINNE_DOWNLOADED=1
    SCRIPT_URL="https://raw.githubusercontent.com/Gesinne/rpi-azure-bridge/main/install.sh"
    TEMP_SCRIPT="/tmp/gesinne_install_$$.sh"
    echo "  [~] Descargando script..."
    curl -sL "$SCRIPT_URL" -o "$TEMP_SCRIPT" 2>/dev/null || wget -qO "$TEMP_SCRIPT" "$SCRIPT_URL"
    chmod +x "$TEMP_SCRIPT"
    exec sudo bash "$TEMP_SCRIPT" "$@" </dev/tty
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
    echo "  [OK] Comando 'Actualizar' instalado"
fi

# Auto-detectar si necesita clonar o actualizar el repo
USER_HOME="/home/$(logname 2>/dev/null || echo ${SUDO_USER:-$USER})"
INSTALL_DIR="$USER_HOME/rpi-azure-bridge"

download_repo_fallback() {
    local dest_dir="$1"
    local tmp_tgz="/tmp/rpi_azure_bridge_${$}.tgz"
    rm -rf "$dest_dir" 2>/dev/null || true
    mkdir -p "$dest_dir"

    if curl -fsSL "https://codeload.github.com/Gesinne/rpi-azure-bridge/tar.gz/refs/heads/main" -o "$tmp_tgz" 2>/dev/null || wget -qO "$tmp_tgz" "https://codeload.github.com/Gesinne/rpi-azure-bridge/tar.gz/refs/heads/main" 2>/dev/null; then
        if tar -xzf "$tmp_tgz" -C "$dest_dir" --strip-components=1 2>/dev/null; then
            rm -f "$tmp_tgz" 2>/dev/null || true
            return 0
        fi
    fi

    rm -f "$tmp_tgz" 2>/dev/null || true
    return 1
}

# Si no se ha actualizado aún (argumento --updated), actualizar y re-ejecutar desde el repo
if [ "$1" != "--updated" ]; then
    echo ""
    echo "  [~] Obteniendo última versión..."
    
    # Borrar y clonar siempre
    rm -rf "$INSTALL_DIR" 2>/dev/null || true
    if ! git clone https://github.com/Gesinne/rpi-azure-bridge.git "$INSTALL_DIR" 2>/dev/null; then
        if ! download_repo_fallback "$INSTALL_DIR"; then
            echo "  [X] No se pudo descargar el software (sin acceso a github.com)"
            exit 1
        fi
    fi
    
    # Copiar scripts de email y lectura de registros
    if [ -f "$INSTALL_DIR/enviar_email.py" ]; then
        cp "$INSTALL_DIR/enviar_email.py" "$USER_HOME/enviar_email.py"
        echo "  [OK] enviar_email.py copiado"
    fi
    if [ -f "$INSTALL_DIR/leer_registros.py" ]; then
        cp "$INSTALL_DIR/leer_registros.py" "$USER_HOME/leer_registros.py"
        echo "  [OK] leer_registros.py copiado"
    fi
    
    # Copiar y configurar script de alerta de reinicio
    if [ -f "$INSTALL_DIR/alerta_reinicio.sh" ]; then
        if [ -f /usr/local/bin/alerta_reinicio.sh ] && crontab -l 2>/dev/null | grep -q "alerta_reinicio.sh"; then
            # Ya instalado, solo actualizar el script
            cp "$INSTALL_DIR/alerta_reinicio.sh" /usr/local/bin/alerta_reinicio.sh
            chmod +x /usr/local/bin/alerta_reinicio.sh
            echo "  [OK] Script alerta_reinicio.sh actualizado (ya estaba instalado)"
        else
            # Primera instalación
            cp "$INSTALL_DIR/alerta_reinicio.sh" /usr/local/bin/alerta_reinicio.sh
            chmod +x /usr/local/bin/alerta_reinicio.sh
            
            # Añadir a crontab @reboot si no existe
            CRON_LINE="@reboot /usr/local/bin/alerta_reinicio.sh >> /var/log/alerta_reinicio.log 2>&1"
            (crontab -l 2>/dev/null | grep -v "alerta_reinicio.sh"; echo "$CRON_LINE") | crontab -
            echo "  [OK] Script alerta_reinicio.sh instalado"
        fi
    fi
    
    # Ejecutar el script del repo con marca de actualizado
    exec bash "$INSTALL_DIR/install.sh" --updated
fi

set -e
cd "$INSTALL_DIR"

echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║                                              ║"
echo "  ║         GESINNE INGENIERÍA                   ║"
echo "  ║                                              ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""

# Verificar que se ejecuta como root
if [ "$EUID" -ne 0 ]; then
    echo "  [X] ERROR: Ejecutar con sudo"
    echo ""
    echo "  Usa: curl -sSL https://raw.githubusercontent.com/Gesinne/rpi-azure-bridge/main/install.sh | sudo bash"
    echo ""
    exit 1
fi

# Asegurar HDMI siempre activo (evita pantalla negra)
CONFIG_FILE="/boot/firmware/config.txt"
[ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="/boot/config.txt"
if [ -f "$CONFIG_FILE" ]; then
    grep -q "^hdmi_force_hotplug=1" "$CONFIG_FILE" 2>/dev/null || echo "hdmi_force_hotplug=1" | sudo tee -a "$CONFIG_FILE" > /dev/null 2>&1 || true
    grep -q "^hdmi_blanking=0" "$CONFIG_FILE" 2>/dev/null || echo "hdmi_blanking=0" | sudo tee -a "$CONFIG_FILE" > /dev/null 2>&1 || true
fi

# Instalar alerta de reinicio no programado
ALERTA_SCRIPT="/usr/local/bin/alerta_reinicio.sh"
if [ ! -f "$ALERTA_SCRIPT" ]; then
    curl -sSL "https://raw.githubusercontent.com/Gesinne/rpi-azure-bridge/main/alerta_reinicio.sh" -o "$ALERTA_SCRIPT" 2>/dev/null
    if [ -f "$ALERTA_SCRIPT" ]; then
        chmod +x "$ALERTA_SCRIPT"
        # Añadir al crontab si no existe
        if ! crontab -l 2>/dev/null | grep -q "alerta_reinicio"; then
            (crontab -l 2>/dev/null; echo "@reboot $ALERTA_SCRIPT >> /var/log/alerta_reinicio.log 2>&1") | crontab -
        fi
    fi
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
            tls = '[SSL] SSL' if node.get('usetls') else '[noSSL] Sin SSL'
            print(f'{broker}:{port} {tls}')
            break
except:
    print('No detectado')
" 2>/dev/null)
        echo "  [M] Node-RED MQTT: $BROKER_INFO"
    else
        echo "  [M] Node-RED: No detectado"
    fi
}

# Función para preguntar si volver al menú o salir
volver_menu() {
    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -p "  Pulsa ENTER para volver al menú (0 para salir): " VOLVER
    if [ "$VOLVER" = "0" ]; then
        echo ""
        echo "  [~] Ajustando permisos de Node-RED..."
        for d in /home/*/.node-red/node_modules; do
            if [ -d "$d" ]; then
                OWNER=$(stat -c '%U:%G' "$(dirname "$d")" 2>/dev/null)
                sudo chown -R "$OWNER" "$d" 2>/dev/null || true
            fi
        done
        echo "  [B] ¡Hasta luego!"
        echo ""
        exit 0
    fi
}

# Función para npm install con auto-limpieza si falla
npm_install_clean() {
    local PACKAGE="$1"
    local NODERED_DIR="$2"
    local USER_HOME=$(dirname "$NODERED_DIR")
    
    # Limpiar residuos antes de instalar
    sudo find "$NODERED_DIR/node_modules" -maxdepth 2 -type d -name ".*-*" -exec rm -rf {} + 2>/dev/null || true
    
    # Intentar instalar
    if sudo npm install "$PACKAGE" 2>&1 | tee /tmp/npm_install_$$.log | while read line; do echo "  $line"; done; then
        rm -f /tmp/npm_install_$$.log
        return 0
    fi
    
    # Si falla con ENOTEMPTY, limpiar y reintentar
    if grep -q "ENOTEMPTY" /tmp/npm_install_$$.log 2>/dev/null; then
        echo ""
        echo "  [!] Error ENOTEMPTY detectado, limpiando caché..."
        sudo find "$NODERED_DIR/node_modules" -maxdepth 2 -type d -name ".*-*" -exec rm -rf {} + 2>/dev/null || true
        sudo rm -rf "$USER_HOME/.npm/_cacache" 2>/dev/null || true
        sudo rm -rf /root/.npm/_cacache 2>/dev/null || true
        echo "  [~] Reintentando instalación..."
        sudo npm install "$PACKAGE" 2>&1 | while read line; do echo "  $line"; done
    fi
    
    rm -f /tmp/npm_install_$$.log
}

# Función para reiniciar Node-RED y kiosko
reiniciar_nodered() {
    echo ""
    read -p "  ¿Reiniciar Node-RED ahora? [y/N]: " CONFIRMAR_RESTART
    if [[ ! "$CONFIRMAR_RESTART" =~ ^[Yy]$ ]]; then
        echo "  [!] Reinicio cancelado. Recuerda reiniciar manualmente:"
        echo "      sudo systemctl restart nodered"
        return 0
    fi
    
    echo "  [~] Reiniciando Node-RED..."
    sudo systemctl restart nodered 2>/dev/null
    sleep 3
    echo "  [OK] Node-RED reiniciado"
    
    # Iniciar kiosko si existe el servicio
    if systemctl list-unit-files kiosk.service &>/dev/null; then
        echo "  [~] Reiniciando kiosko..."
        sudo systemctl restart kiosk.service 2>/dev/null
        sleep 2
        echo "  [OK] Kiosko reiniciado"
    fi
}

# Función para añadir credenciales de chronos-config (sin borrar las existentes)
crear_chronos_credentials() {
    NODERED_DIR="$1"
    CHRONOS_ID="$2"
    LAT="$3"
    LON="$4"
    CRED_SECRET="Gesinne20."
    USER_DIR=$(basename $(dirname "$NODERED_DIR"))
    
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

# Función para hacer deploy vía API de Node-RED (fuerza recarga de flows)
deploy_nodered() {
    FLOWS_FILE="$1"
    NR_USER="gesinne"
    NR_PASS="Gesinne20."
    
    # Obtener token
    TOKEN=$(curl -s -X POST http://localhost:1880/auth/token \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "client_id=node-red-admin&grant_type=password&scope=*&username=$NR_USER&password=$NR_PASS" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
    
    if [ -n "$TOKEN" ]; then
        # Hacer deploy
        curl -s -X POST http://localhost:1880/flows \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Node-RED-Deployment-Type: full" \
          -d @"$FLOWS_FILE" >/dev/null 2>&1
        echo "  [OK] Deploy realizado"
    else
        echo "  [!] No se pudo hacer deploy automático"
    fi
}

# Verificar y reparar Logo + httpStatic si falta
for NODERED_DIR in /home/*/.node-red; do
    if [ -d "$NODERED_DIR" ]; then
        USER_HOME_DIR=$(dirname "$NODERED_DIR")
        SETTINGS_FILE="$NODERED_DIR/settings.js"
        CREDS_FILE="/opt/nodered-flows-cache/.git_credentials"
        NEED_RESTART=false
        
        # Si no existe carpeta Logo, intentar descargarla del repo
        if [ ! -d "$USER_HOME_DIR/Logo" ]; then
            echo ""
            echo "  [!]  Falta carpeta Logo, descargando..."
            
            # Cargar credenciales si existen
            REPO_URL="https://github.com/Gesinne/nodered-flows.git"
            if [ -f "$CREDS_FILE" ]; then
                source "$CREDS_FILE"
                if [ -n "$GIT_USER" ] && [ -n "$GIT_TOKEN" ]; then
                    REPO_URL="https://${GIT_USER}:${GIT_TOKEN}@github.com/Gesinne/nodered-flows.git"
                fi
            fi
            
            TEMP_LOGO="/tmp/logo_download_$$"
            rm -rf "$TEMP_LOGO" 2>/dev/null
            if git clone --depth 1 "$REPO_URL" "$TEMP_LOGO" 2>/dev/null; then
                if [ -d "$TEMP_LOGO/Logo" ]; then
                    cp -r "$TEMP_LOGO/Logo" "$USER_HOME_DIR/"
                    chown -R $(basename "$USER_HOME_DIR"):$(basename "$USER_HOME_DIR") "$USER_HOME_DIR/Logo" 2>/dev/null
                    echo "  [OK] Carpeta Logo instalada en $USER_HOME_DIR/Logo"
                    NEED_RESTART=true
                else
                    echo "  [X] No se encontró carpeta Logo en el repo"
                fi
            else
                echo "  [X] No se pudo descargar (¿credenciales?)"
            fi
            rm -rf "$TEMP_LOGO" 2>/dev/null
        fi
        
        # Si existe Logo pero no está configurado httpStatic
        if [ -d "$USER_HOME_DIR/Logo" ] && [ -f "$SETTINGS_FILE" ]; then
            # Comprobar si httpStatic está activo (no comentado)
            if ! grep -E "^\s*httpStatic:" "$SETTINGS_FILE" | grep -v "^\s*//" > /dev/null 2>&1; then
                echo "  [!]  Falta httpStatic en settings.js, configurando..."
                
                # Usar python para modificar de forma segura
                python3 << EOFPYTHON
import re

with open('$SETTINGS_FILE', 'r') as f:
    content = f.read()

# Primero intentar descomentar y modificar httpStatic existente
# Buscar //httpStatic: ... y reemplazar
pattern_commented = r'//\s*httpStatic:\s*[\'"][^\'"]*[\'"]'
if re.search(pattern_commented, content):
    new_content = re.sub(pattern_commented, "httpStatic: '$USER_HOME_DIR/Logo/'", content, count=1)
else:
    # Si no existe, añadir después de module.exports = {
    pattern = r'(module\.exports\s*=\s*\{)'
    replacement = r"\1\n    httpStatic: '$USER_HOME_DIR/Logo/',"
    new_content = re.sub(pattern, replacement, content, count=1)

if new_content != content:
    with open('$SETTINGS_FILE', 'w') as f:
        f.write(new_content)
    print("OK")
else:
    print("NO_MATCH")
EOFPYTHON
                    
                if grep -E "^\s*httpStatic:" "$SETTINGS_FILE" | grep -v "^\s*//" > /dev/null 2>&1; then
                    echo "  [OK] httpStatic configurado en settings.js"
                    NEED_RESTART=true
                else
                    echo "  [!]  No se pudo configurar automáticamente"
                    echo "  → Añade manualmente en settings.js:"
                    echo "     httpStatic: '$USER_HOME_DIR/Logo/',"
                fi
            fi
        fi
        
        # Reiniciar Node-RED si hubo cambios
        if [ "$NEED_RESTART" = true ]; then
            reiniciar_nodered
            echo ""
            read -p "  Presiona ENTER para continuar..."
        fi
        break
    fi
done

# Bucle del menú principal
while true; do
    clear
    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  [*] Gesinne RPI Azure Bridge - Instalador"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Mostrar estado
    if [ -f "$OVERRIDE_FILE" ]; then
        echo "  [OK] Bridge Azure IoT instalado"
    else
        echo "  [!]  Bridge no configurado"
    fi
    show_nodered_config

    # Mostrar URL del kiosko si existe
    KIOSK_SCRIPT="/home/$(logname 2>/dev/null || echo ${SUDO_USER:-gesinne})/kiosk.sh"
    if [ -f "$KIOSK_SCRIPT" ]; then
        KIOSK_URL=$(grep -oP 'http://[^ ]+' "$KIOSK_SCRIPT" 2>/dev/null | head -1)
        if [ -n "$KIOSK_URL" ]; then
            if echo "$KIOSK_URL" | grep -q "/dashboard"; then
                echo "  [S]  Kiosko: $KIOSK_URL (FlowFuse)"
            elif echo "$KIOSK_URL" | grep -q "/ui"; then
                echo "  [S]  Kiosko: $KIOSK_URL (Clásico)"
            else
                echo "  [S]  Kiosko: $KIOSK_URL"
            fi
        fi
    fi
    echo ""
    echo "  ¿Qué deseas hacer?"
    echo ""
    echo "  1) Modo de conexión (Azure IoT / Servidor Remoto)"
    echo "  2) Actualizar Flow Node-RED"
    echo "  3) Ver/Modificar configuración equipo"
    echo "  4) Ver/Modificar registros de la placa"
    echo "  5) Revisar espacio y logs"
    echo "  6) Gestionar paleta Node-RED"
    echo "  0) Salir"
    echo ""
    read -p "  Opción [0-6]: " OPTION

    case $OPTION in
        0)
            echo ""
            echo "  [~] Ajustando permisos de Node-RED..."
            for d in /home/*/.node-red/node_modules; do
                if [ -d "$d" ]; then
                    OWNER=$(stat -c '%U:%G' "$(dirname "$d")" 2>/dev/null)
                    sudo chown -R "$OWNER" "$d" 2>/dev/null || true
                fi
            done
            echo "  [B] ¡Hasta luego!"
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
                *) echo "  [X] Opción no válida"; continue ;;
            esac
            
            # La configuración de Azure se ejecuta después del case
            # Salir del bucle para ejecutar el código de Azure
            break
            ;;
        3)
            while true; do
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
    print(f\"  [*] Serie: {data.get('serie', '?')}\")
    print(f\"  [W] Potencia: {data.get('potencia', '?')} kW\")
    print(f\"  [I] Imax: {data.get('Imax', '?')} A\")
    # Mostrar tramos
    t1 = data.get('tramo1', 0)
    t2 = data.get('tramo2', 0)
    t3 = data.get('tramo3', 0)
    t4 = data.get('tramo4', 0)
    print(f\"  [#] Tramos: T1={t1} T2={t2} T3={t3} T4={t4}\")
    # Mostrar valor guardado
    vg = data.get('valorguardado', None)
    if vg is not None:
        print(f\"  [D] Valor guardado: {vg}\")
    # Mostrar cualquier otro campo adicional
    campos_base = {'serie', 'potencia', 'Imax', 'tramo1', 'tramo2', 'tramo3', 'tramo4', 'valorguardado'}
    otros = {k: v for k, v in data.items() if k not in campos_base}
    for k, v in otros.items():
        print(f\"  📌 {k}: {v}\")
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
                print(f'  [i] Versión Flow: {match.group(1)}')
                version_found = True
                break
    
    if not version_found:
        # Buscar en todo el archivo
        with open('$flowfile') as file:
            content = file.read()
        match = re.search(r'([0-9]{4}_[0-9]{2}_[0-9]{2}_[a-zA-Z0-9]+)', content)
        if match:
            print(f'  [i] Versión Flow: {match.group(1)}')
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
    print(f'  [P] Firmware: L1={fw1} L2={fw2} L3={fw3}')
except:
    pass
" 2>/dev/null
                    break
                fi
            done
            
            # Mostrar configuración chronos-config desde flows.json
            for flowfile in /home/*/.node-red/flows.json; do
                if [ -f "$flowfile" ]; then
                    python3 -c "
import json
try:
    with open('$flowfile') as f:
        flows = json.load(f)
    for node in flows:
        if node.get('type') == 'chronos-config':
            tz = node.get('timezone', '') or 'Europe/Madrid'
            lat = node.get('latitude', '') or '43.53099'
            lon = node.get('longitude', '') or '-5.71694'
            print(f'  [T] Chronos: {tz} ({lat}, {lon})')
            break
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
            print(f'  [E] Cola máxima: {maxq} (RAM: {mem_gb:.1f} GB → recomendado: {recommended})')
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
            echo "  [D] Disco: ${USADO}/${TOTAL} usado (${LIBRE} libre) ${PORCENTAJE}"
            
            show_nodered_config
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
                echo "  [-] Node-RED: $NODERED_VERSION [OK]"
            elif [ "$NODERED_LATEST" != "?" ]; then
                echo "  [-] Node-RED: $NODERED_VERSION → v$NODERED_LATEST disponible [^]"
            else
                echo "  [-] Node-RED: $NODERED_VERSION"
            fi
            
            # Versión Node.js
            NODE_VERSION=$(node --version 2>/dev/null || echo "No instalado")
            # Solo mostrar versión instalada, sin complicar con LTS
            echo "  [+] Node.js: $NODE_VERSION [OK]"
            
            # Versión RPI Connect
            if command -v rpi-connect &> /dev/null; then
                RPICONNECT_VERSION=$(rpi-connect --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")
                RPICONNECT_STATUS=$(systemctl is-active rpi-connect 2>/dev/null || echo "inactivo")
                # Comprobar última versión disponible
                RPICONNECT_LATEST=$(apt-cache policy rpi-connect 2>/dev/null | grep Candidate | awk '{print $2}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "?")
                
                if [ "$RPICONNECT_STATUS" = "active" ]; then
                    STATUS_ICON="[+] activo"
                else
                    STATUS_ICON="[-] inactivo"
                fi
                
                if [ "$RPICONNECT_VERSION" = "$RPICONNECT_LATEST" ] || [ "$RPICONNECT_LATEST" = "?" ]; then
                    echo "  [>] RPI Connect: v$RPICONNECT_VERSION ($STATUS_ICON) [OK]"
                else
                    echo "  [>] RPI Connect: v$RPICONNECT_VERSION → v$RPICONNECT_LATEST disponible [^] ($STATUS_ICON)"
                fi
            else
                echo "  [>] RPI Connect: No instalado"
            fi
            echo ""
            
            # Mostrar encoding actual
            SETTINGS_FILE=""
            for sf in /home/*/.node-red/settings.js; do
                if [ -f "$sf" ]; then
                    SETTINGS_FILE="$sf"
                    break
                fi
            done
            
            if [ -n "$SETTINGS_FILE" ]; then
                if grep -q "httpNodeMiddleware" "$SETTINGS_FILE"; then
                    echo "  [A] Encoding UTF-8: [OK] Configurado"
                else
                    echo "  [A] Encoding UTF-8: [!] No configurado (puede dar problemas con acentos)"
                fi
            fi
            
            # Mostrar locale del sistema
            CURRENT_LOCALE=$(cat /etc/default/locale 2>/dev/null | grep "^LANG=" | cut -d= -f2)
            if echo "$CURRENT_LOCALE" | grep -q "UTF-8"; then
                echo "  [G] Locale sistema: [OK] $CURRENT_LOCALE"
            else
                echo "  [G] Locale sistema: [!] ${CURRENT_LOCALE:-no configurado} (debería ser UTF-8)"
            fi
            echo ""
            
            # Preguntar si quiere modificar configuración
            echo "  ¿Qué quieres modificar?"
            echo ""
            echo "  1) Configuración equipo (serie, potencia, tramos)"
            echo "  2) Cola máxima guaranteed-delivery (maxQueue)"
            echo "  3) Actualizar Core Node-RED"
            echo "  4) Instalar/Actualizar RPI Connect"
            echo "  5) Configurar encoding UTF-8 (acentos)"
            echo "  6) Ver/Editar settings.js de Node-RED"
            echo "  7) Configurar contextStorage (persistir variables)"
            echo "  8) Configurar locale UTF-8 (sistema)"
            echo "  9) Configurar Chronos (zona horaria)"
            echo "  0) Volver al menú principal"
            echo ""
            read -p "  Opción [0-9]: " MODIFY
            
            # Salir al menú principal si se pulsa 0 o Enter
            if [ -z "$MODIFY" ] || [ "$MODIFY" = "0" ]; then
                break
            fi
            
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
                    echo "  [OK] maxQueue actualizado a $NEW_MAXQUEUE"
                    echo ""
                    reiniciar_nodered
                fi
                volver_menu
                continue
            fi
            
            if [ "$MODIFY" = "1" ]; then
                # Si no existe el archivo, crearlo pidiendo los valores
                if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
                    echo ""
                    echo "  [!]  No existe equipo_config.json, se creará uno nuevo"
                    echo ""
                    echo "  Por favor, introduce los datos del equipo:"
                    echo ""
                    
                    CONFIG_DIR="/home/$(logname 2>/dev/null || echo ${SUDO_USER:-gesinne})/config"
                    CONFIG_FILE="$CONFIG_DIR/equipo_config.json"
                    mkdir -p "$CONFIG_DIR"
                    
                    read -p "  Serie: " NEW_SERIE
                    read -p "  Potencia (kW): " NEW_POTENCIA
                    read -p "  Imax (A): " NEW_IMAX
                    read -p "  Tramo 1: " NEW_T1
                    read -p "  Tramo 2: " NEW_T2
                    read -p "  Tramo 3: " NEW_T3
                    read -p "  Tramo 4: " NEW_T4
                    read -p "  Valor guardado: " NEW_VG
                    
                    # Guardar configuración inicial
                    python3 -c "
import json
data = {
    'serie': '$NEW_SERIE',
    'potencia': int('$NEW_POTENCIA') if '$NEW_POTENCIA' else 0,
    'Imax': int('$NEW_IMAX') if '$NEW_IMAX' else 0,
    'tramo1': int('$NEW_T1') if '$NEW_T1' else 0,
    'tramo2': int('$NEW_T2') if '$NEW_T2' else 0,
    'tramo3': int('$NEW_T3') if '$NEW_T3' else 0,
    'tramo4': int('$NEW_T4') if '$NEW_T4' else 0,
    'valorguardado': int('$NEW_VG') if '$NEW_VG' else 0
}
with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=4)
" 2>/dev/null
                    
                    echo ""
                    echo "  [OK] Archivo creado: $CONFIG_FILE"
                    echo "  [OK] Configuración guardada"
                    echo ""
                    reiniciar_nodered
                    volver_menu
                    continue
                fi
                
                # Leer valores actuales
                CURRENT_SERIE=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('serie', ''))" 2>/dev/null)
                CURRENT_POTENCIA=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('potencia', 0))" 2>/dev/null)
                CURRENT_IMAX=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('Imax', 0))" 2>/dev/null)
                CURRENT_T1=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('tramo1', 0))" 2>/dev/null)
                CURRENT_T2=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('tramo2', 0))" 2>/dev/null)
                CURRENT_T3=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('tramo3', 0))" 2>/dev/null)
                CURRENT_T4=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('tramo4', 0))" 2>/dev/null)
                CURRENT_VG=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('valorguardado', 0))" 2>/dev/null)
                
                echo ""
                read -p "  Serie [$CURRENT_SERIE]: " NEW_SERIE
                read -p "  Potencia [$CURRENT_POTENCIA]: " NEW_POTENCIA
                read -p "  Imax [$CURRENT_IMAX]: " NEW_IMAX
                read -p "  Tramo 1 [$CURRENT_T1]: " NEW_T1
                read -p "  Tramo 2 [$CURRENT_T2]: " NEW_T2
                read -p "  Tramo 3 [$CURRENT_T3]: " NEW_T3
                read -p "  Tramo 4 [$CURRENT_T4]: " NEW_T4
                read -p "  Valor guardado [$CURRENT_VG]: " NEW_VG
                
                # Usar valores actuales si no se introducen nuevos
                NEW_SERIE="${NEW_SERIE:-$CURRENT_SERIE}"
                NEW_POTENCIA="${NEW_POTENCIA:-$CURRENT_POTENCIA}"
                NEW_IMAX="${NEW_IMAX:-$CURRENT_IMAX}"
                NEW_T1="${NEW_T1:-$CURRENT_T1}"
                NEW_T2="${NEW_T2:-$CURRENT_T2}"
                NEW_T3="${NEW_T3:-$CURRENT_T3}"
                NEW_T4="${NEW_T4:-$CURRENT_T4}"
                NEW_VG="${NEW_VG:-$CURRENT_VG}"
                
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
    'tramo4': int('$NEW_T4') if '$NEW_T4' else 0,
    'valorguardado': int('$NEW_VG') if '$NEW_VG' else 0
}
with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=4)
" 2>/dev/null
                
                echo ""
                echo "  [OK] Configuración guardada"
                echo ""
                reiniciar_nodered
            fi
            
            if [ "$MODIFY" = "3" ]; then
                # Llamar al script externo de actualización de Node-RED
                SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
                if [ -f "$SCRIPT_DIR/actualizar_nodered.sh" ]; then
                    bash "$SCRIPT_DIR/actualizar_nodered.sh"
                elif [ -f "$INSTALL_DIR/actualizar_nodered.sh" ]; then
                    bash "$INSTALL_DIR/actualizar_nodered.sh"
                else
                    # Descargar script si no existe localmente
                    NODERED_SCRIPT_URL="https://raw.githubusercontent.com/Gesinne/rpi-azure-bridge/main/actualizar_nodered.sh"
                    TEMP_NODERED_SCRIPT="/tmp/actualizar_nodered_$$.sh"
                    if curl -sL "$NODERED_SCRIPT_URL" -o "$TEMP_NODERED_SCRIPT" 2>/dev/null || wget -qO "$TEMP_NODERED_SCRIPT" "$NODERED_SCRIPT_URL" 2>/dev/null; then
                        chmod +x "$TEMP_NODERED_SCRIPT"
                        bash "$TEMP_NODERED_SCRIPT"
                        rm -f "$TEMP_NODERED_SCRIPT"
                    else
                        echo "  [X] No se pudo encontrar actualizar_nodered.sh"
                    fi
                fi
            fi
            
            if [ "$MODIFY" = "4" ]; then
                # Instalar/Actualizar RPI Connect
                echo ""
                
                if command -v rpi-connect &> /dev/null; then
                    echo "  [~] Actualizando RPI Connect..."
                    sudo apt-get update
                    sudo apt-get install -y rpi-connect
                else
                    echo "  [P] Instalando RPI Connect..."
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
                RPICONNECT_VERSION=$(rpi-connect --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")
                echo "  [OK] RPI Connect: v$RPICONNECT_VERSION"
                
                # Comprobar si está vinculado
                RPICONNECT_STATUS=$(rpi-connect status 2>&1)
                if echo "$RPICONNECT_STATUS" | grep -qi "not signed in\|no está\|sin vincular"; then
                    echo ""
                    echo "  [!]  RPI Connect no está vinculado"
                    echo ""
                    read -p "  ¿Vincular ahora? [S/n]: " DO_SIGNIN
                    if [ "$DO_SIGNIN" != "n" ] && [ "$DO_SIGNIN" != "N" ]; then
                        echo ""
                        echo "  [>] Iniciando vinculación..."
                        echo "  → Se abrirá un enlace. Cópialo en tu navegador para vincular."
                        echo ""
                        rpi-connect signin
                        echo ""
                        echo "  [OK] Proceso de vinculación iniciado"
                        echo "     Accede desde: https://connect.raspberrypi.com"
                    fi
                else
                    echo "  [+] RPI Connect ya está vinculado"
                fi
                
                # Asegurar HDMI siempre activo (evita pantalla negra)
                CONFIG_FILE="/boot/firmware/config.txt"
                if [ ! -f "$CONFIG_FILE" ]; then
                    CONFIG_FILE="/boot/config.txt"
                fi
                
                if [ -f "$CONFIG_FILE" ]; then
                    HDMI_CHANGED=false
                    if ! grep -q "^hdmi_force_hotplug=1" "$CONFIG_FILE"; then
                        echo "hdmi_force_hotplug=1" | sudo tee -a "$CONFIG_FILE" > /dev/null
                        HDMI_CHANGED=true
                    fi
                    if ! grep -q "^hdmi_blanking=0" "$CONFIG_FILE"; then
                        echo "hdmi_blanking=0" | sudo tee -a "$CONFIG_FILE" > /dev/null
                        HDMI_CHANGED=true
                    fi
                    
                    if [ "$HDMI_CHANGED" = true ]; then
                        echo ""
                        echo "  [OK] Configuración HDMI añadida (evita pantalla negra)"
                        echo "  [!]  Requiere reinicio para aplicar"
                    fi
                fi
            fi
            
            if [ "$MODIFY" = "5" ]; then
                # Configurar encoding UTF-8
                echo ""
                
                SETTINGS_FILE=""
                for sf in /home/*/.node-red/settings.js; do
                    if [ -f "$sf" ]; then
                        SETTINGS_FILE="$sf"
                        break
                    fi
                done
                
                if [ -z "$SETTINGS_FILE" ]; then
                    echo "  [X] No se encontró settings.js"
                else
                    if grep -q "httpNodeMiddleware" "$SETTINGS_FILE"; then
                        echo "  [OK] El encoding UTF-8 ya está configurado"
                    else
                        echo "  [*] Configurando encoding UTF-8..."
                        
                        # Añadir httpNodeMiddleware para UTF-8
                        python3 << EOFUTF8
import re

with open('$SETTINGS_FILE', 'r') as f:
    content = f.read()

# Buscar module.exports = { y añadir httpNodeMiddleware después
middleware_code = '''
    httpNodeMiddleware: function(req,res,next) {
        res.setHeader('Content-Type', 'text/html; charset=utf-8');
        next();
    },'''

pattern = r'(module\.exports\s*=\s*\{)'
replacement = r'\1' + middleware_code

new_content = re.sub(pattern, replacement, content, count=1)

if new_content != content:
    with open('$SETTINGS_FILE', 'w') as f:
        f.write(new_content)
    print("OK")
else:
    print("NO_MATCH")
EOFUTF8
                        
                        if grep -q "httpNodeMiddleware" "$SETTINGS_FILE"; then
                            echo "  [OK] Encoding UTF-8 configurado"
                            echo ""
                            reiniciar_nodered
                        else
                            echo "  [!]  No se pudo configurar automáticamente"
                            echo ""
                            echo "  → Añade manualmente en settings.js:"
                            echo '     httpNodeMiddleware: function(req,res,next) {'
                            echo "         res.setHeader('Content-Type', 'text/html; charset=utf-8');"
                            echo '         next();'
                            echo '     },'
                        fi
                    fi
                fi
            fi
            
            if [ "$MODIFY" = "6" ]; then
                # Ver/Editar settings.js
                echo ""
                
                SETTINGS_FILE=""
                for sf in /home/*/.node-red/settings.js; do
                    if [ -f "$sf" ]; then
                        SETTINGS_FILE="$sf"
                        break
                    fi
                done
                
                if [ -z "$SETTINGS_FILE" ]; then
                    echo "  [X] No se encontró settings.js"
                else
                    echo "  📄 Archivo: $SETTINGS_FILE"
                    echo ""
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Configuraciones activas (no comentadas):"
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo ""
                    
                    # Mostrar líneas importantes (activas y comentadas)
                    echo "  Activas:"
                    grep -E "^\s*(uiPort|httpStatic|httpNodeMiddleware|adminAuth|httpRoot|userDir|flowFile|credentialSecret)" "$SETTINGS_FILE" 2>/dev/null | grep -v "^\s*//" | head -10 | while read line; do
                        echo "    [OK] $line"
                    done
                    
                    # Mostrar si falta httpStatic o httpNodeMiddleware
                    echo ""
                    echo "  Estado de configuraciones importantes:"
                    if grep -E "^\s*httpStatic:" "$SETTINGS_FILE" | grep -v "^\s*//" > /dev/null 2>&1; then
                        echo "    [OK] httpStatic (Logo): Configurado"
                    else
                        echo "    [X] httpStatic (Logo): NO configurado"
                    fi
                    
                    if grep -q "httpNodeMiddleware" "$SETTINGS_FILE" && ! grep "httpNodeMiddleware" "$SETTINGS_FILE" | head -1 | grep -q "^\s*//"; then
                        echo "    [OK] httpNodeMiddleware (UTF-8): Configurado"
                    else
                        echo "    [X] httpNodeMiddleware (UTF-8): NO configurado - puede dar problemas con acentos"
                    fi
                    
                    if grep -E "^\s*contextStorage:" "$SETTINGS_FILE" | grep -v "^\s*//" > /dev/null 2>&1; then
                        echo "    [OK] contextStorage: Configurado (variables persisten)"
                    else
                        echo "    [X] contextStorage: NO configurado - variables se pierden al reiniciar"
                    fi
                    
                    echo ""
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo ""
                    echo "  1) Ver archivo completo"
                    echo "  2) Editar con nano"
                    echo "  0) Volver"
                    echo ""
                    read -p "  Opción [0-2]: " SETTINGS_OPT
                    
                    case $SETTINGS_OPT in
                        1)
                            echo ""
                            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                            echo "  Contenido de settings.js"
                            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                            echo ""
                            cat -n "$SETTINGS_FILE" | head -100
                            echo ""
                            echo "  ... (mostrando primeras 100 líneas)"
                            echo ""
                            read -p "  Presiona ENTER para continuar..."
                            ;;
                        2)
                            echo ""
                            echo "  [!]  Cuidado al editar. Guarda con Ctrl+O, sal con Ctrl+X"
                            echo ""
                            read -p "  Presiona ENTER para abrir nano..."
                            sudo nano "$SETTINGS_FILE"
                            echo ""
                            read -p "  ¿Reiniciar Node-RED para aplicar cambios? [S/n]: " RESTART_NR
                            if [ "$RESTART_NR" != "n" ] && [ "$RESTART_NR" != "N" ]; then
                                reiniciar_nodered
                            fi
                            ;;
                    esac
                fi
            fi
            
            if [ "$MODIFY" = "7" ]; then
                # Configurar contextStorage
                echo ""
                
                SETTINGS_FILE=""
                for sf in /home/*/.node-red/settings.js; do
                    if [ -f "$sf" ]; then
                        SETTINGS_FILE="$sf"
                        break
                    fi
                done
                
                if [ -z "$SETTINGS_FILE" ]; then
                    echo "  [X] No se encontró settings.js"
                else
                    if grep -E "^\s*contextStorage:" "$SETTINGS_FILE" | grep -v "^\s*//" > /dev/null 2>&1; then
                        echo "  [OK] contextStorage ya está configurado"
                    else
                        echo "  [*] Configurando contextStorage..."
                        
                        # Añadir contextStorage
                        python3 << EOFCONTEXT
import re

with open('$SETTINGS_FILE', 'r') as f:
    content = f.read()

# Configuración de contextStorage
context_code = '''
    contextStorage: {
        default: {
            module: "memory"
        },
        file: {
            module: "localfilesystem"
        }
    },'''

# Buscar si hay contextStorage comentado y reemplazar
pattern_commented = r'//\s*contextStorage:\s*\{'
if re.search(pattern_commented, content):
    # Hay uno comentado, mejor añadir uno nuevo
    pattern = r'(module\.exports\s*=\s*\{)'
    replacement = r'\1' + context_code
    new_content = re.sub(pattern, replacement, content, count=1)
else:
    # Añadir después de module.exports = {
    pattern = r'(module\.exports\s*=\s*\{)'
    replacement = r'\1' + context_code
    new_content = re.sub(pattern, replacement, content, count=1)

if new_content != content:
    with open('$SETTINGS_FILE', 'w') as f:
        f.write(new_content)
    print("OK")
else:
    print("NO_MATCH")
EOFCONTEXT
                        
                        if grep -E "^\s*contextStorage:" "$SETTINGS_FILE" | grep -v "^\s*//" > /dev/null 2>&1; then
                            echo "  [OK] contextStorage configurado"
                            echo ""
                            reiniciar_nodered
                            echo ""
                            echo "  [i]  Ahora las variables de contexto se guardan en disco"
                            echo "     y persisten después de reiniciar Node-RED"
                        else
                            echo "  [!]  No se pudo configurar automáticamente"
                            echo ""
                            echo "  → Añade manualmente en settings.js:"
                            echo '     contextStorage: {'
                            echo '         default: { module: "memory" },'
                            echo '         file: { module: "localfilesystem" }'
                            echo '     },'
                        fi
                    fi
                fi
            fi
            
            if [ "$MODIFY" = "8" ]; then
                # Configurar locale UTF-8
                echo ""
                echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  Configurar locale UTF-8 (sistema)"
                echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                
                CURRENT_LOCALE=$(cat /etc/default/locale 2>/dev/null | grep "^LANG=" | cut -d= -f2)
                echo "  Locale actual: ${CURRENT_LOCALE:-no configurado}"
                echo ""
                echo "  Selecciona locale:"
                echo "    1) en_GB.UTF-8 (Inglés UK - recomendado)"
                echo "    2) es_ES.UTF-8 (Español España)"
                echo "    0) Cancelar"
                echo ""
                read -p "  Opción [1]: " LOCALE_CHOICE
                
                case "$LOCALE_CHOICE" in
                    2) NEW_LOCALE="es_ES.UTF-8" ;;
                    0) continue ;;
                    *) NEW_LOCALE="en_GB.UTF-8" ;;
                esac
                
                if [ "$CURRENT_LOCALE" = "$NEW_LOCALE" ]; then
                    echo ""
                    echo "  [OK] El locale ya está configurado como $NEW_LOCALE"
                else
                    echo ""
                    echo "  [*] Configurando locale $NEW_LOCALE..."
                    echo ""
                    
                    # Generar locale si no existe
                    LOCALE_SHORT=$(echo "$NEW_LOCALE" | sed 's/UTF-8/utf8/' | tr '[:upper:]' '[:lower:]')
                    if ! locale -a 2>/dev/null | grep -qi "${LOCALE_SHORT}"; then
                        echo "  → Generando locale $NEW_LOCALE..."
                        sudo locale-gen "$NEW_LOCALE" 2>/dev/null || true
                    fi
                    
                    # Configurar locale
                    echo "  → Configurando como predeterminado..."
                    sudo bash -c "echo \"LANG=$NEW_LOCALE
LC_ALL=$NEW_LOCALE
LANGUAGE=$NEW_LOCALE\" > /etc/default/locale"
                    
                    echo ""
                    echo "  [OK] Locale configurado como $NEW_LOCALE"
                    echo ""
                    echo "  [!]  Es necesario REINICIAR para aplicar los cambios"
                    echo ""
                    read -p "  ¿Reiniciar ahora? [S/n]: " DO_REBOOT
                    if [ "$DO_REBOOT" != "n" ] && [ "$DO_REBOOT" != "N" ]; then
                        echo ""
                        echo "  [~] Reiniciando en 3 segundos..."
                        sleep 3
                        sudo reboot
                    else
                        echo ""
                        echo "  [i]  Recuerda reiniciar manualmente: sudo reboot"
                    fi
                fi
            fi
            
            if [ "$MODIFY" = "9" ]; then
                # Configurar Chronos (zona horaria)
                echo ""
                echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  Configurar Chronos (zona horaria)"
                echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                
                FLOWS_FILE=""
                for f in /home/*/.node-red/flows.json; do
                    if [ -f "$f" ]; then
                        FLOWS_FILE="$f"
                        break
                    fi
                done
                
                if [ -n "$FLOWS_FILE" ]; then
                    # Obtener valores actuales
                    CURRENT_CHRONOS=$(python3 -c "
import json
try:
    with open('$FLOWS_FILE') as f:
        flows = json.load(f)
    for node in flows:
        if node.get('type') == 'chronos-config':
            tz = node.get('timezone', '')
            lat = node.get('latitude', '')
            lon = node.get('longitude', '')
            print(f'{lat}|{lon}|{tz}')
            break
except:
    pass
" 2>/dev/null)
                    
                    CURRENT_LAT=$(echo "$CURRENT_CHRONOS" | cut -d'|' -f1)
                    CURRENT_LON=$(echo "$CURRENT_CHRONOS" | cut -d'|' -f2)
                    CURRENT_TZ=$(echo "$CURRENT_CHRONOS" | cut -d'|' -f3)
                    
                    # Detectar si está vacío/inválido
                    CHRONOS_INVALID="no"
                    if [ -z "$CURRENT_LAT" ] || [ -z "$CURRENT_LON" ] || [ -z "$CURRENT_TZ" ]; then
                        CHRONOS_INVALID="yes"
                    fi
                    if ! echo "$CURRENT_TZ" | grep -q "/"; then
                        CHRONOS_INVALID="yes"
                    fi
                    
                    # Valores por defecto si están vacíos
                    CURRENT_LAT="${CURRENT_LAT:-43.53099}"
                    CURRENT_LON="${CURRENT_LON:--5.71694}"
                    CURRENT_TZ="${CURRENT_TZ:-Europe/Madrid}"
                    
                    if [ "$CHRONOS_INVALID" = "yes" ]; then
                        echo "  [!] Chronos NO configurado o inválido"
                        echo ""
                        echo "  ¿Configurar automáticamente con valores por defecto?"
                        echo "    Latitud:  43.53099 (Gijon)"
                        echo "    Longitud: -5.71694 (Gijon)"
                        echo "    Zona:     Europe/Madrid"
                        echo ""
                        read -p "  ¿Aplicar configuración automática? [S/n]: " AUTO_CONFIG
                        
                        if [ "$AUTO_CONFIG" != "n" ] && [ "$AUTO_CONFIG" != "N" ]; then
                            NEW_LAT="43.53099"
                            NEW_LON="-5.71694"
                            NEW_TZ="Europe/Madrid"
                            
                            echo ""
                            echo "  [~] Parando Node-RED..."
                            sudo systemctl stop nodered
                            sleep 2
                            
                            python3 -c "
import json
with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)
for node in flows:
    if node.get('type') == 'chronos-config':
        node['latitude'] = '$NEW_LAT'
        node['longitude'] = '$NEW_LON'
        node['timezone'] = '$NEW_TZ'
        node['latitudeType'] = 'num'
        node['longitudeType'] = 'num'
        node['timezoneType'] = 'str'
with open('$FLOWS_FILE', 'w') as f:
    json.dump(flows, f, indent=4)
" 2>/dev/null
                            
                            echo "  [OK] Chronos configurado automáticamente"
                            echo ""
                            read -p "  ¿Iniciar Node-RED ahora? [y/N]: " CONFIRMAR_START
                            if [[ "$CONFIRMAR_START" =~ ^[Yy]$ ]]; then
                                echo "  [~] Iniciando Node-RED..."
                                sudo systemctl start nodered
                                sleep 3
                                echo "  [OK] Node-RED iniciado"
                            else
                                echo "  [!] Node-RED NO iniciado. Recuerda iniciarlo manualmente:"
                                echo "      sudo systemctl start nodered"
                            fi
                            continue
                        fi
                    fi
                    
                    echo "  Configuración actual:"
                    echo "    Latitud:  $CURRENT_LAT"
                    echo "    Longitud: $CURRENT_LON"
                    echo "    Zona:     $CURRENT_TZ"
                    echo ""
                    
                    read -p "  Latitud [$CURRENT_LAT]: " NEW_LAT
                    read -p "  Longitud [$CURRENT_LON]: " NEW_LON
                    echo ""
                    echo "  Zonas horarias comunes:"
                    echo "    1) Europe/Madrid"
                    echo "    2) Europe/London"
                    echo "    3) Atlantic/Canary"
                    echo "    4) America/Mexico_City"
                    echo "    5) Otra (escribir)"
                    echo ""
                    read -p "  Zona horaria [1]: " TZ_CHOICE
                    
                    case "$TZ_CHOICE" in
                        2) NEW_TZ="Europe/London" ;;
                        3) NEW_TZ="Atlantic/Canary" ;;
                        4) NEW_TZ="America/Mexico_City" ;;
                        5) read -p "  Escribe zona horaria: " NEW_TZ ;;
                        *) NEW_TZ="Europe/Madrid" ;;
                    esac
                    
                    NEW_LAT="${NEW_LAT:-$CURRENT_LAT}"
                    NEW_LON="${NEW_LON:-$CURRENT_LON}"
                    
                    echo ""
                    echo "  [~] Parando Node-RED..."
                    sudo systemctl stop nodered
                    sleep 2
                    
                    CHRONOS_ID=$(python3 -c "
import json
with open('$FLOWS_FILE', 'r') as f:
    flows = json.load(f)
chronos_id = None
for node in flows:
    if node.get('type') == 'chronos-config':
        chronos_id = node.get('id')
        node['latitude'] = '$NEW_LAT'
        node['longitude'] = '$NEW_LON'
        node['timezone'] = '$NEW_TZ'
        node['latitudeType'] = 'num'
        node['longitudeType'] = 'num'
        node['timezoneType'] = 'str'
with open('$FLOWS_FILE', 'w') as f:
    json.dump(flows, f, indent=4)
if chronos_id:
    print(chronos_id)
" 2>/dev/null)
                    
                    echo "  [OK] Chronos configurado:"
                    echo "    Latitud:  $NEW_LAT"
                    echo "    Longitud: $NEW_LON"
                    echo "    Zona:     $NEW_TZ"
                    
                    # Crear credenciales para chronos
                    if [ -n "$CHRONOS_ID" ]; then
                        NODERED_DIR=$(dirname "$FLOWS_FILE")
                        crear_chronos_credentials "$NODERED_DIR" "$CHRONOS_ID" "$NEW_LAT" "$NEW_LON"
                        echo "  [OK] Credenciales chronos creadas"
                    fi
                    
                    echo ""
                    read -p "  ¿Iniciar Node-RED ahora? [y/N]: " CONFIRMAR_START
                    if [[ "$CONFIRMAR_START" =~ ^[Yy]$ ]]; then
                        echo "  [~] Iniciando Node-RED..."
                        sudo systemctl start nodered
                        sleep 5
                        echo "  [OK] Node-RED iniciado"
                        
                        # Reiniciar kiosko si existe
                        if systemctl list-unit-files kiosk.service &>/dev/null; then
                            echo "  [~] Reiniciando kiosko..."
                            sudo systemctl restart kiosk.service 2>/dev/null
                            sleep 2
                            echo "  [OK] Kiosko reiniciado"
                        fi
                    else
                        echo "  [!] Node-RED NO iniciado. Recuerda iniciarlo manualmente:"
                        echo "      sudo systemctl start nodered"
                    fi
                else
                    echo "  [X] No se encontró flows.json"
                fi
            fi
            
            done
            volver_menu
            ;;
        2)
            # Llamar al script externo de actualización de flow
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            if [ -f "$SCRIPT_DIR/actualizar_flow.sh" ]; then
                bash "$SCRIPT_DIR/actualizar_flow.sh"
            elif [ -f "$INSTALL_DIR/actualizar_flow.sh" ]; then
                bash "$INSTALL_DIR/actualizar_flow.sh"
            else
                # Descargar script si no existe localmente
                FLOW_SCRIPT_URL="https://raw.githubusercontent.com/Gesinne/rpi-azure-bridge/main/actualizar_flow.sh"
                TEMP_FLOW_SCRIPT="/tmp/actualizar_flow_$$.sh"
                if curl -sL "$FLOW_SCRIPT_URL" -o "$TEMP_FLOW_SCRIPT" 2>/dev/null || wget -qO "$TEMP_FLOW_SCRIPT" "$FLOW_SCRIPT_URL" 2>/dev/null; then
                    chmod +x "$TEMP_FLOW_SCRIPT"
                    bash "$TEMP_FLOW_SCRIPT"
                    rm -f "$TEMP_FLOW_SCRIPT"
                else
                    echo "  [X] No se pudo encontrar actualizar_flow.sh"
                fi
            fi
            
            volver_menu
            ;;
        4)
            echo ""
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Ver los 112 registros de la placa"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  ¿Qué tarjeta quieres leer?"
            echo ""
            echo "  1) Tarjeta L1 (Fase 1)"
            echo "  2) Tarjeta L2 (Fase 2)"
            echo "  3) Tarjeta L3 (Fase 3)"
            echo "  4) TODAS en columnas (L1, L2, L3)"
            echo "  5) Diagnóstico valores clavados (3 placas)"
            echo "  6) Leer registro específico"
            echo "  7) Enviar parámetros por EMAIL"
            echo "  8) Escribir registro"
            echo "  9) Diagnóstico configuración (límites)"
            echo "  10) Cambiar tensión consigna (reg 37) - 3 placas"
            echo "  11) Escribir Nº Serie en placas (reg 41)"
            echo "  12) Reparar memoria corrupta (diagnóstico + fix)"
            echo "  0) Volver al menú"
            echo ""
            read -p "  Opción [0-12]: " TARJETA
            
            case $TARJETA in
                0) continue ;;
                1) UNIT_IDS="1"; FASES="L1"; MODO_COLUMNAS="no" ;;
                2) UNIT_IDS="2"; FASES="L2"; MODO_COLUMNAS="no" ;;
                3) UNIT_IDS="3"; FASES="L3"; MODO_COLUMNAS="no" ;;
                4) UNIT_IDS="1 2 3"; FASES="L1 L2 L3"; MODO_COLUMNAS="yes" ;;
                5) 
                    # Diagnóstico de valores clavados
                    echo ""
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  DIAGNÓSTICO DE VALORES CLAVADOS"
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo ""
                    echo "  Este diagnóstico lee valores críticos de las 3 placas"
                    echo "  para detectar problemas con offsets, calibración y"
                    echo "  valores que no cambian (clavados)."
                    echo ""
                    echo "  [!] Parando Node-RED temporalmente..."
                    
                    sudo systemctl stop nodered 2>/dev/null
                    docker stop gesinne-rpi >/dev/null 2>&1 || true
                    sleep 2
                    echo "  [OK] Servicios parados"
                    echo ""
                    
                    # Detectar puerto serie
                    DIAG_PORT=""
                    for port in /dev/ttyAMA0 /dev/serial0 /dev/ttyUSB0 /dev/ttyACM0 /dev/ttyS0; do
                        if [ -e "$port" ]; then
                            DIAG_PORT="$port"
                            echo "  [OK] Puerto serie: $DIAG_PORT"
                            break
                        fi
                    done
                    
                    if [ -z "$DIAG_PORT" ]; then
                        echo "  [X] No se encontró ningún puerto serie"
                        volver_menu
                        continue
                    fi
                    echo ""
                    
                    python3 << EOFDIAG
import sys
import time
import os

try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    try:
        from pymodbus.client.sync import ModbusSerialClient
    except ImportError:
        print("  [X] pymodbus no instalado")
        sys.exit(1)

PUERTO = "$DIAG_PORT"
BAUDRATES = [115200, 57600, 9600]

client = None
connected = False

for baudrate in BAUDRATES:
    try:
        client = ModbusSerialClient(
            port=PUERTO,
            baudrate=baudrate,
            bytesize=8,
            parity='N',
            stopbits=1,
            timeout=2
        )
        
        if client.connect():
            # Probar lectura con placa L1 (unit_id=1)
            result = client.read_holding_registers(address=0, count=1, slave=1)
            if not result.isError():
                print(f"  [OK] Conectado a {PUERTO} @ {baudrate} baud")
                connected = True
                break
            client.close()
    except Exception as e:
        if client:
            client.close()
        continue

if not connected:
    print(f"  [X] No se pudo comunicar con las placas")
    print(f"      Puerto: {PUERTO}")
    print(f"      Baudrates probados: {BAUDRATES}")
    print("")
    print("  Posibles causas:")
    print("      • Las placas no están conectadas o alimentadas")
    print("      • El cable serie está desconectado")
    print("      • Otro proceso está usando el puerto")
    sys.exit(1)

# Registros críticos para diagnóstico
REGS_DIAGNOSTICO = {
    # Tiempo real - si están clavados hay problema
    3: "V salida",
    4: "V entrada",
    5: "Frecuencia",
    6: "I Salida",
    7: "I Chopper",
    15: "Factor Potencia",
    17: "Temperatura",
    # Calibración - valores K y b
    71: "Ca00 (K V salida)",
    72: "Ca01 (K V entrada)",
    73: "Ca03 (b V salida)",
    74: "Ca04 (b V entrada)",
    75: "Ca06 (K I Chopper)",
    76: "Ca07 (K I Salida)",
    77: "Ca08 (b I Chopper)",
    78: "Ca09 (b I Salida)",
    79: "Ca10 (Ruido I Chop)",
    80: "Ca11 (Ruido I Sal)",
}

# Valores esperados/límites para calibración
LIMITES_CALIB = {
    71: (8000, 12000, "K tensión salida"),
    72: (8000, 12000, "K tensión entrada"),
    73: (0, 500, "b tensión salida"),
    74: (0, 500, "b tensión entrada"),
    75: (8000, 12000, "K corriente chopper"),
    76: (8000, 12000, "K corriente salida"),
    77: (0, 500, "b corriente chopper"),
    78: (0, 500, "b corriente salida"),
    79: (0, 100, "Ruido I chopper"),
    80: (0, 100, "Ruido I salida"),
}

print("  ╔════════════════════════════════════════════════════════════════════════════════╗")
print("  ║  DIAGNÓSTICO DE VALORES CLAVADOS - 3 PLACAS                                    ║")
print("  ╚════════════════════════════════════════════════════════════════════════════════╝")
print("")

# Primera lectura
print("  [1/2] Primera lectura...")
data_lectura1 = {}
for unit_id in [1, 2, 3]:
    fase = {1: "L1", 2: "L2", 3: "L3"}[unit_id]
    data = []
    for start in range(0, 112, 40):
        count = min(40, 112 - start)
        result = client.read_holding_registers(address=start, count=count, slave=unit_id)
        if not result.isError():
            data.extend(result.registers)
        else:
            break
    data_lectura1[unit_id] = data if len(data) >= 81 else None
    status = "[OK]" if data_lectura1[unit_id] else "[X]"
    print(f"        {fase}: {status}")

# Esperar 2 segundos
print("")
print("  [~] Esperando 2 segundos para segunda lectura...")
time.sleep(2)

# Segunda lectura
print("  [2/2] Segunda lectura...")
data_lectura2 = {}
for unit_id in [1, 2, 3]:
    fase = {1: "L1", 2: "L2", 3: "L3"}[unit_id]
    data = []
    for start in range(0, 112, 40):
        count = min(40, 112 - start)
        result = client.read_holding_registers(address=start, count=count, slave=unit_id)
        if not result.isError():
            data.extend(result.registers)
        else:
            break
    data_lectura2[unit_id] = data if len(data) >= 81 else None
    status = "[OK]" if data_lectura2[unit_id] else "[X]"
    print(f"        {fase}: {status}")

client.close()

# Análisis de resultados
print("")
print("  ════════════════════════════════════════════════════════════════════════════════")
print("  ANÁLISIS DE VALORES EN TIEMPO REAL (deben cambiar)")
print("  ════════════════════════════════════════════════════════════════════════════════")
print("")
print(f"  {'Reg':<4} {'Parámetro':<18} {'L1 t1':>7} {'L1 t2':>7} {'L2 t1':>7} {'L2 t2':>7} {'L3 t1':>7} {'L3 t2':>7}  Estado")
print(f"  {'─'*4} {'─'*18} {'─'*7} {'─'*7} {'─'*7} {'─'*7} {'─'*7} {'─'*7}  {'─'*12}")

problemas = []
for reg in [3, 4, 5, 6, 7, 15, 17]:
    nombre = REGS_DIAGNOSTICO.get(reg, f"Reg {reg}")
    valores = []
    clavados = []
    
    for unit_id in [1, 2, 3]:
        d1 = data_lectura1.get(unit_id)
        d2 = data_lectura2.get(unit_id)
        
        if d1 and d2 and len(d1) > reg and len(d2) > reg:
            v1, v2 = d1[reg], d2[reg]
            valores.append((v1, v2))
            # Valores que deberían cambiar (excepto temperatura que cambia lento)
            if reg != 17 and v1 == v2 and v1 != 0:
                clavados.append(unit_id)
        else:
            valores.append((None, None))
    
    # Formatear salida
    cols = []
    for v1, v2 in valores:
        if v1 is not None:
            cols.append(f"{v1:>7}")
            cols.append(f"{v2:>7}")
        else:
            cols.append("    ---")
            cols.append("    ---")
    
    estado = ""
    if clavados:
        fases_clavadas = ", ".join([f"L{u}" for u in clavados])
        estado = f"⚠️  CLAVADO en {fases_clavadas}"
        problemas.append(f"Reg {reg} ({nombre}) clavado en {fases_clavadas}")
    elif all(v[0] is not None for v in valores):
        estado = "✓ OK"
    
    print(f"  {reg:<4} {nombre:<18} {cols[0]} {cols[1]} {cols[2]} {cols[3]} {cols[4]} {cols[5]}  {estado}")

print("")
print("  ════════════════════════════════════════════════════════════════════════════════")
print("  ANÁLISIS DE CALIBRACIÓN (valores K y b)")
print("  ════════════════════════════════════════════════════════════════════════════════")
print("")
print(f"  {'Reg':<4} {'Parámetro':<20} {'L1':>8} {'L2':>8} {'L3':>8}  {'Rango esperado':<20} Estado")
print(f"  {'─'*4} {'─'*20} {'─'*8} {'─'*8} {'─'*8}  {'─'*20} {'─'*12}")

for reg in [71, 72, 73, 74, 75, 76, 77, 78, 79, 80]:
    nombre = REGS_DIAGNOSTICO.get(reg, f"Reg {reg}")
    min_val, max_val, desc = LIMITES_CALIB.get(reg, (0, 65535, ""))
    
    valores = []
    fuera_rango = []
    
    for unit_id in [1, 2, 3]:
        d = data_lectura1.get(unit_id)
        if d and len(d) > reg:
            v = d[reg]
            valores.append(v)
            if v < min_val or v > max_val:
                fuera_rango.append(unit_id)
        else:
            valores.append(None)
    
    cols = [f"{v:>8}" if v is not None else "     ---" for v in valores]
    rango_str = f"{min_val}-{max_val}"
    
    estado = ""
    if fuera_rango:
        fases = ", ".join([f"L{u}" for u in fuera_rango])
        estado = f"⚠️  FUERA en {fases}"
        problemas.append(f"Reg {reg} ({nombre}) fuera de rango en {fases}")
    elif all(v is not None for v in valores):
        estado = "✓ OK"
    
    print(f"  {reg:<4} {nombre:<20} {cols[0]} {cols[1]} {cols[2]}  {rango_str:<20} {estado}")

# Comparar valores entre fases (deben ser similares)
print("")
print("  ════════════════════════════════════════════════════════════════════════════════")
print("  COMPARACIÓN ENTRE FASES (diferencias significativas)")
print("  ════════════════════════════════════════════════════════════════════════════════")
print("")

for reg, nombre in [(3, "V salida"), (4, "V entrada"), (6, "I Salida"), (17, "Temperatura")]:
    valores = []
    for unit_id in [1, 2, 3]:
        d = data_lectura1.get(unit_id)
        if d and len(d) > reg:
            valores.append(d[reg])
        else:
            valores.append(None)
    
    vals_validos = [v for v in valores if v is not None]
    if len(vals_validos) >= 2:
        diff = max(vals_validos) - min(vals_validos)
        # Umbral de diferencia significativa
        umbral = 50 if reg == 17 else (100 if reg in [3, 4] else 50)
        
        cols = [f"{v:>8}" if v is not None else "     ---" for v in valores]
        estado = f"⚠️  Diff={diff}" if diff > umbral else f"✓ Diff={diff}"
        
        if diff > umbral:
            problemas.append(f"{nombre}: diferencia de {diff} entre fases")
        
        print(f"  {nombre:<20} L1={cols[0]}  L2={cols[1]}  L3={cols[2]}  {estado}")

# Resumen final
print("")
print("  ════════════════════════════════════════════════════════════════════════════════")
print("  RESUMEN DEL DIAGNÓSTICO")
print("  ════════════════════════════════════════════════════════════════════════════════")
print("")

if problemas:
    print("  ⚠️  PROBLEMAS DETECTADOS:")
    for p in problemas:
        print(f"      • {p}")
    print("")
    print("  POSIBLES CAUSAS:")
    print("      • Offsets dinámicos saturados (OFFSET_MAX/MIN)")
    print("      • ADC no convirtiendo correctamente")
    print("      • Calibración incorrecta o corrupta")
    print("      • Interrupción PWM no ejecutándose")
    print("      • Problema de comunicación Modbus")
else:
    print("  ✓ No se detectaron problemas evidentes")
    print("    Los valores cambian correctamente y la calibración está en rango.")

print("")
EOFDIAG
                    
                    # Reiniciar servicios
                    echo ""
                    read -p "  ¿Reiniciar servicios ahora? [y/N]: " CONFIRMAR_RESTART
                    if [[ "$CONFIRMAR_RESTART" =~ ^[Yy]$ ]]; then
                        echo "  [~] Reiniciando servicios..."
                        sudo systemctl start nodered
                        docker start gesinne-rpi 2>/dev/null || true
                        echo "  [OK] Listo"
                    else
                        echo "  [!] Servicios NO reiniciados. Recuerda iniciarlos manualmente:"
                        echo "      sudo systemctl start nodered"
                    fi
                    
                    volver_menu
                    continue
                    ;;
                6)
                    # Leer registro específico
                    echo ""
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Leer registro específico"
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo ""
                    echo "  ¿Qué placa?"
                    echo "  1) L1   2) L2   3) L3   4) TODAS"
                    echo ""
                    read -p "  Placa [1-4]: " REG_PLACA
                    
                    case $REG_PLACA in
                        1) REG_UNITS="1"; REG_FASES="L1" ;;
                        2) REG_UNITS="2"; REG_FASES="L2" ;;
                        3) REG_UNITS="3"; REG_FASES="L3" ;;
                        4) REG_UNITS="1 2 3"; REG_FASES="L1 L2 L3" ;;
                        *) echo "  [X] Placa no válida"; volver_menu; continue ;;
                    esac
                    
                    echo ""
                    read -p "  Número de registro [0-200]: " REG_NUM
                    
                    if ! [[ "$REG_NUM" =~ ^[0-9]+$ ]] || [ "$REG_NUM" -gt 200 ]; then
                        echo "  [X] Registro no válido"
                        volver_menu
                        continue
                    fi
                    
                    echo ""
                    echo "  [!] Parando Node-RED temporalmente..."
                    sudo systemctl stop nodered 2>/dev/null
                    docker stop gesinne-rpi >/dev/null 2>&1 || true
                    sleep 2
                    echo "  [OK] Servicios parados"
                    echo ""
                    
                    python3 << EOFREG
import sys
try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    try:
        from pymodbus.client.sync import ModbusSerialClient
    except ImportError:
        print("  [X] pymodbus no instalado")
        sys.exit(1)

# Detectar puerto serie
import os
port = None
for p in ['/dev/ttyAMA0', '/dev/serial0', '/dev/ttyUSB0', '/dev/ttyACM0', '/dev/ttyS0']:
    if os.path.exists(p):
        port = p
        break

if not port:
    print("  [X] No se encontró puerto serie")
    sys.exit(1)

client = ModbusSerialClient(
    port=port,
    baudrate=115200,
    bytesize=8,
    parity='N',
    stopbits=1,
    timeout=1
)

if not client.connect():
    print("  [X] No se pudo conectar al puerto serie")
    sys.exit(1)

import time

unit_ids = [int(x) for x in "$REG_UNITS".split()]
fases = "$REG_FASES".split()
reg_num = $REG_NUM

# Diccionario de nombres de registros
NOMBRES_REG = {
    0: "Estado actual", 1: "Topología actual", 2: "Alarma", 3: "V salida", 4: "V entrada",
    5: "Frecuencia", 6: "I Salida", 7: "I Chopper", 8: "I Primario trafo",
    9: "P activa (H)", 10: "P activa (L)", 11: "P reactiva (H)", 12: "P reactiva (L)",
    13: "P aparente (H)", 14: "P aparente (L)", 15: "Factor Potencia", 16: "Tipo FP",
    17: "Temperatura", 18: "T alarma", 19: "Enable externo", 20: "T reencendido", 21: "Enable PCB",
    30: "Flag Estado", 31: "Estado deseado", 32: "Consigna deseada", 33: "Bucle control", 34: "Mando",
    40: "Flag Config", 41: "Nº Serie placa", 42: "V nominal", 43: "V prim autotrafo",
    44: "V sec autotrafo", 45: "V sec trafo", 46: "Topología", 47: "Dead-time",
    48: "Dir Modbus", 49: "I nom salida", 50: "I nom chopper", 51: "I max chopper",
    52: "I max pico", 53: "T apagado CC", 54: "Cnt apagados SC", 55: "Estado inicial",
    56: "V consigna inicial", 57: "T máxima", 58: "Dec T reenc", 59: "Cnt apagados ST",
    60: "Tipo alimentación", 61: "Vel Modbus", 62: "Package transistores",
    63: "Ángulo cargas altas", 64: "Ángulo cargas bajas", 65: "% carga baja",
    66: "Sens transitorios", 67: "Sens derivada", 69: "ReCo",
    70: "Flag Calibración", 71: "K V salida", 72: "K V entrada", 73: "b V salida",
    74: "b V entrada", 75: "K I chopper", 76: "K I equipo", 77: "b I chopper",
    78: "b I equipo", 79: "Ruido I chopper", 80: "Ruido I equipo", 81: "K potencia",
    82: "b potencia", 83: "Desfase V-I", 84: "Cal frecuencia", 85: "Cal ruido", 86: "ReCa",
    90: "Flag Control", 91: "A control V", 92: "B control V", 93: "EMM", 94: "EMMVT0", 95: "EMMVT1",
    96: "ReCn", 100: "Versión FW", 101: "Tipo FW", 102: "Microprocesador",
    103: "FLASH restaurada", 104: "Frec PWM", 105: "Mando apagado (MA)",
    106: "Mando mínimo", 107: "Mando máximo", 110: "Flag RESET FW", 111: "RESET FW"
}

nombre_reg = NOMBRES_REG.get(reg_num, "Desconocido")

if len(unit_ids) == 1:
    # Una sola placa
    print(f"  [M] Leyendo registro {reg_num} ({nombre_reg}) de placa {fases[0]}...")
    print("")
    result = client.read_holding_registers(address=reg_num, count=1, slave=unit_ids[0])
    if result.isError():
        print(f"  [X] Error leyendo registro {reg_num}")
    else:
        valor = result.registers[0]
        print(f"  ┌─────────────────────────────────────────────┐")
        print(f"  │  Placa: {fases[0]}                               │")
        print(f"  │  Registro: {reg_num:<5} ({nombre_reg[:20]:<20}) │")
        print(f"  │  Valor decimal: {valor:<10}                │")
        print(f"  │  Valor hexadecimal: 0x{valor:04X}                 │")
        print(f"  │  Valor binario: {valor:016b}  │")
        print(f"  └─────────────────────────────────────────────┘")
else:
    # Todas las placas - leer con reintentos hasta tener las 3
    print(f"  [M] Leyendo registro {reg_num} ({nombre_reg}) de las 3 placas...")
    print("")
    
    valores = {}
    max_intentos = 5
    
    for intento in range(1, max_intentos + 1):
        fases_pendientes = [f for f in fases if f not in valores or valores[f] is None]
        
        if not fases_pendientes:
            break
        
        if intento > 1:
            print(f"  [~] Reintento {intento}/{max_intentos} - Pendientes: {', '.join(fases_pendientes)}")
            time.sleep(0.5)
        
        for unit_id, fase in zip(unit_ids, fases):
            if fase in valores and valores[fase] is not None:
                continue
            
            result = client.read_holding_registers(address=reg_num, count=1, slave=unit_id)
            if not result.isError():
                valores[fase] = result.registers[0]
                print(f"  [OK] {fase}: {result.registers[0]}")
            else:
                valores[fase] = None
    
    print("")
    
    v1 = valores.get('L1')
    v2 = valores.get('L2')
    v3 = valores.get('L3')
    
    # Verificar si tenemos las 3
    leidas = sum(1 for v in [v1, v2, v3] if v is not None)
    if leidas < 3:
        print(f"  [!] Solo se pudieron leer {leidas}/3 placas")
        print("")
    
    def fmt(v):
        return f"{v:>8}" if v is not None else "   ERR  "
    
    def fmt_hex(v):
        return f"  0x{v:04X}  " if v is not None else "   ERR  "
    
    # Detectar diferencias
    vals = [v for v in [v1, v2, v3] if v is not None]
    diff = "  [!]  " if len(set(vals)) > 1 else "       "
    
    print(f"  ┌─────────────────────────────────────────────────────────┐")
    print(f"  │  Registro: {reg_num:<5} - {nombre_reg[:35]:<35}  │")
    print(f"  ├─────────────────────────────────────────────────────────┤")
    print(f"  │  Formato    │    L1    │    L2    │    L3    │  DIFF   │")
    print(f"  ├─────────────┼──────────┼──────────┼──────────┼─────────┤")
    print(f"  │  Decimal    │{fmt(v1)}  │{fmt(v2)}  │{fmt(v3)}  │{diff}│")
    print(f"  │  Hexadecimal│{fmt_hex(v1)}│{fmt_hex(v2)}│{fmt_hex(v3)}│       │")
    print(f"  └─────────────┴──────────┴──────────┴──────────┴─────────┘")

client.close()
EOFREG
                    
                    echo ""
                    echo "  [~] Reiniciando Node-RED..."
                    sudo systemctl start nodered
                    docker start gesinne-rpi 2>/dev/null || true
                    echo "  [OK] Listo"
                    
                    volver_menu
                    continue
                    ;;
                7)
                    # Enviar parámetros por EMAIL (código movido de opción 5)
                    echo ""
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Enviar parámetros por EMAIL"
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo ""
                    echo "  ¿Qué tarjeta(s) enviar?"
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
                        *) echo "  [X] Opción no válida"; volver_menu; continue ;;
                    esac
                    
                    echo ""
                    echo "  [!] Parando Node-RED temporalmente..."
                    sudo systemctl stop nodered 2>/dev/null
                    docker stop gesinne-rpi >/dev/null 2>&1 || true
                    sleep 2
                    echo "  [OK] Servicios parados"
                    echo ""
                    
                    # Ejecutar script de envío de email
                    EMAIL_SCRIPT="$INSTALL_DIR/enviar_email.py"
                    if [ -f "$EMAIL_SCRIPT" ]; then
                        python3 "$EMAIL_SCRIPT"
                    else
                        # Fallback: buscar en directorio actual
                        if [ -f "./enviar_email.py" ]; then
                            python3 "./enviar_email.py"
                        else
                            echo "  [X] Script de email no encontrado"
                            echo "  Usa la opción 4 (TODAS) para ver los registros en pantalla"
                        fi
                    fi
                    
                    echo ""
                    echo "  [~] Reiniciando Node-RED..."
                    sudo systemctl start nodered
                    docker start gesinne-rpi 2>/dev/null || true
                    echo "  [OK] Listo"
                    
                    volver_menu
                    continue
                    ;;
                8)
                    # Escribir registro
                    echo ""
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Escribir registro"
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo ""
                    echo "  ¿Qué placa?"
                    echo "  1) L1   2) L2   3) L3   4) TODAS"
                    echo ""
                    read -p "  Placa [1-4]: " WRITE_PLACA
                    
                    case $WRITE_PLACA in
                        1) WRITE_UNITS="1"; WRITE_FASES="L1" ;;
                        2) WRITE_UNITS="2"; WRITE_FASES="L2" ;;
                        3) WRITE_UNITS="3"; WRITE_FASES="L3" ;;
                        4) WRITE_UNITS="1 2 3"; WRITE_FASES="L1 L2 L3" ;;
                        *) echo "  [X] Placa no válida"; volver_menu; continue ;;
                    esac
                    
                    echo ""
                    read -p "  Número de registro [0-111]: " WRITE_REG
                    
                    if ! [[ "$WRITE_REG" =~ ^[0-9]+$ ]] || [ "$WRITE_REG" -gt 111 ]; then
                        echo "  [X] Registro no válido"
                        volver_menu
                        continue
                    fi
                    
                    echo ""
                    read -p "  Valor a escribir: " WRITE_VAL
                    
                    if ! [[ "$WRITE_VAL" =~ ^[0-9]+$ ]]; then
                        echo "  [X] Valor no válido (debe ser numérico)"
                        volver_menu
                        continue
                    fi
                    
                    echo ""
                    echo "  ⚠️  CONFIRMACIÓN"
                    echo "  ────────────────────────────────────────"
                    echo "  Placa(s): $WRITE_FASES"
                    echo "  Registro: $WRITE_REG"
                    echo "  Valor: $WRITE_VAL"
                    echo "  ────────────────────────────────────────"
                    echo ""
                    read -p "  ¿Confirmar escritura? (s/N): " CONFIRM_WRITE
                    
                    if [[ ! "$CONFIRM_WRITE" =~ ^[sS]$ ]]; then
                        echo "  [X] Escritura cancelada"
                        volver_menu
                        continue
                    fi
                    
                    echo ""
                    echo "  [!] Parando Node-RED temporalmente..."
                    sudo systemctl stop nodered 2>/dev/null
                    docker stop gesinne-rpi >/dev/null 2>&1 || true
                    sleep 2
                    echo "  [OK] Servicios parados"
                    echo ""
                    
                    python3 << EOFWRITE
import sys
import time
try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    try:
        from pymodbus.client.sync import ModbusSerialClient
    except ImportError:
        print("  [X] pymodbus no instalado")
        sys.exit(1)

import os
port = None
for p in ['/dev/ttyAMA0', '/dev/serial0', '/dev/ttyUSB0', '/dev/ttyACM0', '/dev/ttyS0']:
    if os.path.exists(p):
        port = p
        break

if not port:
    print("  [X] No se encontró puerto serie")
    sys.exit(1)

client = ModbusSerialClient(
    port=port,
    baudrate=115200,
    bytesize=8,
    parity='N',
    stopbits=1,
    timeout=1
)

if not client.connect():
    print("  [X] No se pudo conectar al puerto serie")
    sys.exit(1)

unit_ids = [int(x) for x in "$WRITE_UNITS".split()]
fases = "$WRITE_FASES".split()
reg_num = $WRITE_REG
valor = $WRITE_VAL

MAX_RETRIES = 3

def write_with_retry(client, address, value, slave, description=""):
    """Escribe un registro con reintentos si falla"""
    for attempt in range(MAX_RETRIES):
        result = client.write_register(address=address, value=value, slave=slave)
        if not result.isError():
            return result
        if attempt < MAX_RETRIES - 1:
            print(f"      [!] Reintentando {description} ({attempt+2}/{MAX_RETRIES})...")
            time.sleep(0.3)
    return result

for unit_id, fase in zip(unit_ids, fases):
    print(f"  [M] Escribiendo en {fase}...")
    time.sleep(0.3)
    
    # Si es registro 56: bypass → flag → escribir
    estado_anterior_31 = None
    if reg_num == 56:
        # 1. Primero poner en bypass (reg 31 = 0)
        reg31_result = client.read_holding_registers(address=31, count=1, slave=unit_id)
        if not reg31_result.isError():
            estado_anterior_31 = reg31_result.registers[0]
            print(f"      Estado anterior reg 31: {estado_anterior_31}")
        
        if estado_anterior_31 != 0:
            bypass_result = write_with_retry(client, 31, 0, unit_id, f"bypass {fase}")
            if bypass_result.isError():
                print(f"  [X] Error poniendo en bypass {fase}")
                continue
            print(f"      Bypass aplicado (reg 31 = 0)")
            time.sleep(0.2)
        else:
            print(f"      Ya está en bypass (reg 31 = 0)")
        
        # 2. Resetear y activar flag de configuración (reg 40)
        # Primero desactivar (escribir 0)
        write_with_retry(client, 40, 0, unit_id, f"reset flag {fase}")
        time.sleep(0.2)
        # Luego activar (escribir 47818)
        flag_result = write_with_retry(client, 40, 47818, unit_id, f"flag config {fase}")
        if flag_result.isError():
            print(f"  [X] Error activando flag de configuración en {fase}")
            continue
        print(f"      Flag configuración activado (reg 40 = 47818)")
        time.sleep(0.3)
    
    # Para otros registros de configuración (40-69), solo activar flag 40
    elif 40 <= reg_num <= 69:
        flag_read = client.read_holding_registers(address=40, count=1, slave=unit_id)
        if not flag_read.isError() and flag_read.registers[0] == 47818:
            print(f"      Flag configuración ya activo (reg 40 = 47818)")
        else:
            flag_result = write_with_retry(client, 40, 47818, unit_id, f"flag config {fase}")
            if flag_result.isError():
                print(f"  [X] Error activando flag de configuración en {fase}")
                continue
            print(f"      Flag configuración activado (reg 40 = 47818)")
            time.sleep(0.2)
    
    # Para registros de calibración (70-89), poner en bypass, activar flag 40 y luego flag 70
    elif 70 <= reg_num <= 89:
        # Primero poner en bypass (reg 31 = 0)
        reg31_result = client.read_holding_registers(address=31, count=1, slave=unit_id)
        if not reg31_result.isError():
            estado_anterior_31 = reg31_result.registers[0]
            print(f"      Estado anterior reg 31: {estado_anterior_31}")
        if estado_anterior_31 != 0:
            bypass_result = write_with_retry(client, 31, 0, unit_id, f"bypass {fase}")
            if not bypass_result.isError():
                print(f"      Bypass aplicado (reg 31 = 0)")
            time.sleep(0.2)
        # Activar flag configuración primero
        write_with_retry(client, 40, 0, unit_id, f"reset flag {fase}")
        time.sleep(0.2)
        flag40_result = write_with_retry(client, 40, 47818, unit_id, f"flag config {fase}")
        if not flag40_result.isError():
            print(f"      Flag configuración activado (reg 40 = 47818)")
        time.sleep(0.2)
        # Activar flag calibración
        flag_result = write_with_retry(client, 70, 51898, unit_id, f"flag calib {fase}")
        if flag_result.isError():
            print(f"  [!] Advertencia: flag 70 no respondió, intentando escribir igual...")
        else:
            print(f"      Flag calibración activado (reg 70 = 51898)")
        time.sleep(0.2)
    
    # Para registros de control (90-95), activar flag 90 con verificación
    elif 90 <= reg_num <= 95:
        # Resetear flag primero
        write_with_retry(client, 90, 0, unit_id, f"reset flag control {fase}")
        time.sleep(0.5)
        
        # Activar flag con reintentos y verificación
        flag_ok = False
        for intento in range(5):
            flag_result = write_with_retry(client, 90, 56010, unit_id, f"flag control {fase}")
            time.sleep(0.5)
            
            # Verificar que se quedó activo
            verify = client.read_holding_registers(address=90, count=1, slave=unit_id)
            if not verify.isError() and verify.registers[0] == 56010:
                flag_ok = True
                print(f"      Flag control activado y verificado (reg 90 = 56010)")
                break
            else:
                leido = verify.registers[0] if not verify.isError() else "error"
                print(f"      [!] Flag no verificado (leído: {leido}), reintento {intento+2}/5...")
                time.sleep(0.3)
        
        if not flag_ok:
            print(f"  [X] Error activando flag de control en {fase} tras 5 intentos")
            continue
        time.sleep(0.3)
    
    # Leer valor actual
    read_result = client.read_holding_registers(address=reg_num, count=1, slave=unit_id)
    valor_anterior = None
    if not read_result.isError():
        valor_anterior = read_result.registers[0]
        print(f"      Valor anterior: {valor_anterior}")
    
    # Escribir nuevo valor
    write_result = write_with_retry(client, reg_num, valor, unit_id, f"reg {reg_num} en {fase}")
    
    if write_result.isError():
        print(f"  [X] Error escribiendo en {fase}: {write_result}")
        # Restaurar bypass si falló
        if estado_anterior_31 is not None:
            client.write_register(address=31, value=estado_anterior_31, slave=unit_id)
        continue
    
    # Verificar escritura
    verify_result = client.read_holding_registers(address=reg_num, count=1, slave=unit_id)
    if not verify_result.isError():
        valor_verificado = verify_result.registers[0]
        if valor_verificado == valor:
            print(f"  [OK] {fase}: Escrito correctamente (verificado: {valor_verificado})")
        else:
            print(f"  [!] {fase}: Verificación fallida (esperado {valor}, leído {valor_verificado})")
    
    # Restaurar estado anterior del registro 31
    if estado_anterior_31 is not None:
        time.sleep(0.1)
        restore_result = client.write_register(address=31, value=estado_anterior_31, slave=unit_id)
        if not restore_result.isError():
            print(f"      Estado restaurado (reg 31 = {estado_anterior_31})")
        else:
            print(f"  [!] No se pudo restaurar reg 31")

client.close()
print("")
print("  [OK] Escritura completada")
EOFWRITE
                    
                    echo ""
                    echo "  [~] Reiniciando Node-RED..."
                    sudo systemctl start nodered
                    docker start gesinne-rpi 2>/dev/null || true
                    echo "  [OK] Listo"
                    
                    volver_menu
                    continue
                    ;;
                9)
                    # Diagnóstico de configuración - verificar límites
                    echo ""
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Diagnóstico de configuración (límites)"
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo ""
                    read -p "  Valor a probar para reg 56 (V inicial) [ej: 2350]: " VALOR_TEST
                    VALOR_TEST=${VALOR_TEST:-0}
                    echo ""
                    echo "  [!] Parando Node-RED temporalmente..."
                    sudo systemctl stop nodered 2>/dev/null
                    docker stop gesinne-rpi >/dev/null 2>&1 || true
                    sleep 2
                    echo "  [OK] Servicios parados"
                    echo ""
                    
                    python3 << EOFDIAG
import sys
import time
try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    try:
        from pymodbus.client.sync import ModbusSerialClient
    except ImportError:
        print("  [X] pymodbus no instalado")
        sys.exit(1)

import os
port = None
for p in ['/dev/ttyAMA0', '/dev/serial0', '/dev/ttyUSB0', '/dev/ttyACM0', '/dev/ttyS0']:
    if os.path.exists(p):
        port = p
        break

if not port:
    print("  [X] No se encontró puerto serie")
    sys.exit(1)

client = ModbusSerialClient(
    port=port,
    baudrate=115200,
    bytesize=8,
    parity='N',
    stopbits=1,
    timeout=1
)

if not client.connect():
    print("  [X] No se pudo conectar al puerto serie")
    sys.exit(1)

# Constantes del firmware
WORDS_CFG = 29
FW_VERSION = 1401
MAX_TENSION = 2800
MIN_TENSION = 1100
CONSIGNA_MIN = 80
CONSIGNA_MAX = 120
AUTOTRAFOP_MAX = 2800
AUTOTRAFOP_MIN = 800
TRAFOP_MAX = 3600
TRAFOP_MIN = 1000
TRAFOS_MAX = 1000
TRAFOS_MIN = 60
DT_MAX = 250
DT_MIN = 3
MODBUSAddressMax = 3
MODBUSAddressMin = 1
I_NOM_EMAX = 2500
I_NOM_EMIN = 30
I_NOM_CMAX = 250
I_NOM_CMIN = 15
FACTOR_I_MAX = 20
LIMITEI_MIN = 1
tiempo_apagado_CC_MAX = 300
tiempo_apagado_CC_MIN = 1
TempMaxH = 700
TempMaxL = 450
DecrementoTempMax = 120
DecrementoTempMin = 50
anguloCambio_MAX = 179
anguloCambio_MIN = 0
porcentajeCARGABAJA_MAX = 50
porcentajeCARGABAJA_MIN = 1
SDD_MAX = 6
SDD_MIN = 0

# Mapeo registro Modbus -> índice CConf
REG_TO_CCONF = {
    41: 0,   # Nº Serie -> CConf[0] (pero firmware usa WORDS_CFG=29)
    42: 3,   # V nominal
    43: 4,   # V prim autotrafo
    44: 5,   # V sec autotrafo  
    45: 6,   # V sec trafo
    46: 7,   # Topología
    47: 8,   # Dead-time
    48: 9,   # Dir Modbus
    49: 10,  # I nom salida
    50: 11,  # I nom chopper
    51: 12,  # I max chopper
    52: 13,  # I max pico
    53: 14,  # T apagado CC
    54: 15,  # Cnt apagados SC
    55: 16,  # Estado inicial
    56: 17,  # V inicial (consigna)
    57: 18,  # T máxima
    58: 19,  # Dec T reenc
    59: 20,  # Cnt apagados ST
    60: 21,  # Tipo alimentación
    61: 22,  # Vel Modbus
    62: 23,  # Package transistores
    63: 24,  # Ángulo cargas altas
    64: 25,  # Ángulo cargas bajas
    65: 26,  # % carga baja
    66: 27,  # Sens transitorios
    67: 28,  # Sens derivada
}

def leer_config(client, unit_id):
    """Lee todos los registros de configuración y construye CConf"""
    CConf = [0] * 29
    CConf[0] = WORDS_CFG  # Constante del firmware
    CConf[1] = FW_VERSION  # Constante del firmware
    CConf[2] = 0  # Reservado
    
    for reg, idx in REG_TO_CCONF.items():
        if idx in [0, 1, 2]:  # Ya asignados
            continue
        result = client.read_holding_registers(address=reg, count=1, slave=unit_id)
        if not result.isError():
            CConf[idx] = result.registers[0]
    return CConf

def VerificaTensionConsigna(tension, CConf):
    aux = (CConf[3] * CONSIGNA_MIN) // 100
    aux2 = (CConf[3] * CONSIGNA_MAX) // 100
    if tension > MAX_TENSION or tension > aux2 or tension < aux:
        return False
    return True

def compruebaConfig(CConf, verbose=True):
    """Simula compruebaConfig() del firmware"""
    errores = []
    
    # Línea 67: CConf[0] == WORDS_CFG
    if CConf[0] != WORDS_CFG:
        errores.append(f"CConf[0]={CConf[0]} != WORDS_CFG={WORDS_CFG}")
    
    # Línea 68: CConf[1] == FW_VERSION
    if CConf[1] != FW_VERSION:
        errores.append(f"CConf[1]={CConf[1]} != FW_VERSION={FW_VERSION}")
    
    # Línea 70: V nominal en rango
    if CConf[3] > MAX_TENSION or CConf[3] < MIN_TENSION:
        errores.append(f"CConf[3] (Vnominal)={CConf[3]} fuera de [{MIN_TENSION}-{MAX_TENSION}]")
    
    # Línea 71: V nominal múltiplo de 50
    if CConf[3] % 50:
        errores.append(f"CConf[3] (Vnominal)={CConf[3]} no es múltiplo de 50")
    
    # Línea 72: V prim autotrafo
    if CConf[4] > AUTOTRAFOP_MAX or CConf[4] < AUTOTRAFOP_MIN:
        errores.append(f"CConf[4] (Vprim autotrafo)={CConf[4]} fuera de [{AUTOTRAFOP_MIN}-{AUTOTRAFOP_MAX}]")
    
    # Línea 73: V sec autotrafo
    if CConf[5] > TRAFOP_MAX or CConf[5] < TRAFOP_MIN:
        errores.append(f"CConf[5] (Vsec autotrafo)={CConf[5]} fuera de [{TRAFOP_MIN}-{TRAFOP_MAX}]")
    
    # Línea 74: V sec trafo
    if CConf[6] > TRAFOS_MAX or CConf[6] < TRAFOS_MIN:
        errores.append(f"CConf[6] (Vsec trafo)={CConf[6]} fuera de [{TRAFOS_MIN}-{TRAFOS_MAX}]")
    
    # Línea 75: Topología
    if CConf[7] < 0 or CConf[7] > 4:
        errores.append(f"CConf[7] (Topología)={CConf[7]} fuera de [0-4]")
    
    # Línea 76: Dead-time
    if CConf[8] > DT_MAX or CConf[8] < DT_MIN:
        errores.append(f"CConf[8] (Dead-time)={CConf[8]} fuera de [{DT_MIN}-{DT_MAX}]")
    
    # Línea 77: Dir Modbus
    if CConf[9] > MODBUSAddressMax or CConf[9] < MODBUSAddressMin:
        errores.append(f"CConf[9] (Dir Modbus)={CConf[9]} fuera de [{MODBUSAddressMin}-{MODBUSAddressMax}]")
    
    # Línea 78: I nom salida
    if CConf[10] > I_NOM_EMAX or CConf[10] < I_NOM_EMIN:
        errores.append(f"CConf[10] (I nom salida)={CConf[10]} fuera de [{I_NOM_EMIN}-{I_NOM_EMAX}]")
    
    # Línea 79: I nom chopper
    if CConf[11] > I_NOM_CMAX or CConf[11] < I_NOM_CMIN:
        errores.append(f"CConf[11] (I nom chopper)={CConf[11]} fuera de [{I_NOM_CMIN}-{I_NOM_CMAX}]")
    
    # Línea 82: I max chopper
    aux = CConf[11] * FACTOR_I_MAX
    if CConf[12] > aux or CConf[12] < (LIMITEI_MIN * 10):
        errores.append(f"CConf[12] (I max chopper)={CConf[12]} fuera de [10-{aux}]")
    
    # Línea 83: I max pico
    if CConf[13] > aux or CConf[13] < (LIMITEI_MIN * 10):
        errores.append(f"CConf[13] (I max pico)={CConf[13]} fuera de [10-{aux}]")
    
    # Línea 84: T apagado CC
    if CConf[14] > tiempo_apagado_CC_MAX or CConf[14] < tiempo_apagado_CC_MIN:
        errores.append(f"CConf[14] (T apagado CC)={CConf[14]} fuera de [{tiempo_apagado_CC_MIN}-{tiempo_apagado_CC_MAX}]")
    
    # Línea 86: Estado inicial
    if CConf[16] != 0 and CConf[16] != 2:
        errores.append(f"CConf[16] (Estado inicial)={CConf[16]} debe ser 0 o 2")
    
    # Línea 87: V inicial (consigna) - VerificaTensionConsigna
    if not VerificaTensionConsigna(CConf[17], CConf):
        vmin = (CConf[3] * CONSIGNA_MIN) // 100
        vmax = (CConf[3] * CONSIGNA_MAX) // 100
        errores.append(f"CConf[17] (V inicial)={CConf[17]} fuera de rango consigna [{vmin}-{vmax}]")
    
    # Línea 88: T máxima
    if CConf[18] > TempMaxH or CConf[18] < TempMaxL:
        errores.append(f"CConf[18] (T máxima)={CConf[18]} fuera de [{TempMaxL}-{TempMaxH}]")
    
    # Línea 89: Dec T reenc
    if CConf[19] > DecrementoTempMax or CConf[19] < DecrementoTempMin:
        errores.append(f"CConf[19] (Dec T reenc)={CConf[19]} fuera de [{DecrementoTempMin}-{DecrementoTempMax}]")
    
    # Línea 91: Tipo alimentación
    if CConf[21] != 0 and CConf[21] != 1:
        errores.append(f"CConf[21] (Tipo alimentación)={CConf[21]} debe ser 0 o 1")
    
    # Línea 92: Vel Modbus
    if CConf[22] not in [0, 1, 2]:
        errores.append(f"CConf[22] (Vel Modbus)={CConf[22]} debe ser 0, 1 o 2")
    
    # Línea 93: Package transistores
    if CConf[23] != 0 and CConf[23] != 1:
        errores.append(f"CConf[23] (Package transistores)={CConf[23]} debe ser 0 o 1")
    
    # Línea 94: Ángulo cargas altas
    if CConf[24] > anguloCambio_MAX or CConf[24] < anguloCambio_MIN:
        errores.append(f"CConf[24] (Ángulo cargas altas)={CConf[24]} fuera de [{anguloCambio_MIN}-{anguloCambio_MAX}]")
    
    # Línea 95: Ángulo cargas bajas
    if CConf[25] > anguloCambio_MAX or CConf[25] < anguloCambio_MIN:
        errores.append(f"CConf[25] (Ángulo cargas bajas)={CConf[25]} fuera de [{anguloCambio_MIN}-{anguloCambio_MAX}]")
    
    # Línea 96: % carga baja
    if CConf[26] > porcentajeCARGABAJA_MAX or CConf[26] < porcentajeCARGABAJA_MIN:
        errores.append(f"CConf[26] (% carga baja)={CConf[26]} fuera de [{porcentajeCARGABAJA_MIN}-{porcentajeCARGABAJA_MAX}]")
    
    # Línea 97: Sens transitorios
    if CConf[27] > 4:
        errores.append(f"CConf[27] (Sens transitorios)={CConf[27]} debe ser <= 4")
    
    # Línea 98: Sens derivada
    if CConf[28] > SDD_MAX or CConf[28] < SDD_MIN:
        errores.append(f"CConf[28] (Sens derivada)={CConf[28]} fuera de [{SDD_MIN}-{SDD_MAX}]")
    
    return errores

print("  Leyendo configuración de las 3 placas...")
print("")

# Valor a probar (pasado desde shell)
valor_test = $VALOR_TEST if $VALOR_TEST > 0 else None

for unit_id in [1, 2, 3]:
    fase = f"L{unit_id}"
    print(f"\n  ══════════════════════════════════════════════")
    print(f"  PLACA {fase}")
    print(f"  ══════════════════════════════════════════════")
    
    CConf = leer_config(client, unit_id)
    
    print(f"\n  Valores actuales:")
    print(f"    Reg 42 (V nominal):  {CConf[3]} dV ({CConf[3]/10:.0f}V)")
    print(f"    Reg 56 (V inicial):  {CConf[17]} dV ({CConf[17]/10:.0f}V)")
    
    vmin = (CConf[3] * CONSIGNA_MIN) // 100
    vmax = (CConf[3] * CONSIGNA_MAX) // 100
    print(f"    Rango V inicial:     [{vmin}-{vmax}] dV ({vmin/10:.0f}V-{vmax/10:.0f}V)")
    
    # Test 1: Configuración actual
    print(f"\n  TEST 1: Validación con valores actuales")
    errores = compruebaConfig(CConf)
    if errores:
        print(f"  [X] FALLO - {len(errores)} errores:")
        for e in errores:
            print(f"      - {e}")
    else:
        print(f"  [OK] Configuración actual válida")
    
    # Test 2: Con valor de prueba
    if valor_test:
        print(f"\n  TEST 2: Validación con V inicial = {valor_test}")
        CConf_test = CConf.copy()
        CConf_test[17] = valor_test
        errores = compruebaConfig(CConf_test)
        if errores:
            print(f"  [X] FALLO - {len(errores)} errores:")
            for e in errores:
                print(f"      - {e}")
        else:
            print(f"  [OK] Valor {valor_test} pasaría la validación")
    
    time.sleep(0.2)

client.close()
print("\n  [OK] Diagnóstico completado")
EOFDIAG
                    
                    echo ""
                    echo "  [~] Reiniciando Node-RED..."
                    sudo systemctl start nodered
                    docker start gesinne-rpi 2>/dev/null || true
                    echo "  [OK] Listo"
                    
                    volver_menu
                    continue
                    ;;
                10)
                    # Cambiar tensión de consigna (reg 32) en las 3 placas - MODO OSCILACIÓN
                    echo ""
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Cambiar tensión de consigna (Registro 32)"
                    echo "  MODO OSCILACIÓN CONTINUA"
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo ""
                    echo "  Este modo alterna entre dos valores de tensión continuamente."
                    echo "  Unidad: deciVoltios (ej: 2200 = 220V, 2300 = 230V)"
                    echo ""
                    
                    # Pedir valor 1
                    read -p "  Valor 1 en dV (ej: 2200): " VALOR_1
                    if [ -z "$VALOR_1" ] || ! [[ "$VALOR_1" =~ ^[0-9]+$ ]]; then
                        echo "  [X] Valor no válido"
                        volver_menu
                        continue
                    fi
                    
                    # Pedir valor 2
                    read -p "  Valor 2 en dV (ej: 2300): " VALOR_2
                    if [ -z "$VALOR_2" ] || ! [[ "$VALOR_2" =~ ^[0-9]+$ ]]; then
                        echo "  [X] Valor no válido"
                        volver_menu
                        continue
                    fi
                    
                    # Pedir intervalo
                    read -p "  Intervalo en segundos entre cambios [5]: " INTERVALO
                    INTERVALO=${INTERVALO:-5}
                    if ! [[ "$INTERVALO" =~ ^[0-9]+$ ]]; then
                        INTERVALO=5
                    fi
                    
                    echo ""
                    echo "  ═══════════════════════════════════════════════"
                    echo "  Oscilando entre $VALOR_1 dV y $VALOR_2 dV"
                    echo "  Intervalo: $INTERVALO segundos"
                    echo "  Pulsa Ctrl+C para detener"
                    echo "  ═══════════════════════════════════════════════"
                    echo ""
                    
                    # Ejecutar oscilación en Python (sin parar Node-RED)
                    python3 << EOFOSCILA
import sys
import time
import signal

try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    try:
        from pymodbus.client.sync import ModbusSerialClient
    except ImportError:
        print("  [X] pymodbus no instalado")
        sys.exit(1)

import os

# Manejar Ctrl+C
running = True
def signal_handler(sig, frame):
    global running
    running = False
    print("\n  [~] Deteniendo oscilación...")

signal.signal(signal.SIGINT, signal_handler)

port = None
for p in ['/dev/ttyAMA0', '/dev/serial0', '/dev/ttyUSB0', '/dev/ttyACM0', '/dev/ttyS0']:
    if os.path.exists(p):
        port = p
        break

if not port:
    print("  [X] No se encontró puerto serie")
    sys.exit(1)

client = ModbusSerialClient(
    port=port,
    baudrate=115200,
    bytesize=8,
    parity='N',
    stopbits=1,
    timeout=1
)

if not client.connect():
    print("  [X] No se pudo conectar al puerto serie")
    sys.exit(1)

print(f"  [OK] Conectado a {port}")
print("")

valor_1 = $VALOR_1
valor_2 = $VALOR_2
intervalo = $INTERVALO
FLAG_ESCRITURA = 43981

valores = [valor_1, valor_2]
idx = 0
ciclo = 0

while running:
    nuevo_valor = valores[idx]
    ciclo += 1
    print(f"  [{ciclo}] Escribiendo {nuevo_valor} dV ({nuevo_valor/10:.1f} V)...")
    
    exitos = 0
    for unit_id in [1, 2, 3]:
        # Activar flag
        client.write_register(address=30, value=FLAG_ESCRITURA, slave=unit_id)
        time.sleep(0.05)
        # Escribir valor
        result = client.write_register(address=32, value=nuevo_valor, slave=unit_id)
        if not result.isError():
            exitos += 1
        time.sleep(0.05)
    
    if exitos == 3:
        print(f"      [OK] L1, L2, L3 = {nuevo_valor} dV")
    else:
        print(f"      [!] Solo {exitos}/3 placas")
    
    # Alternar valor
    idx = 1 - idx
    
    # Esperar intervalo
    for _ in range(intervalo * 10):
        if not running:
            break
        time.sleep(0.1)

print("")
print(f"  [OK] Oscilación detenida tras {ciclo} ciclos")
client.close()
EOFOSCILA
                    
                    volver_menu
                    continue
                    ;;
                12)
                    # Reparar memoria corrupta - diagnóstico y fix
                    echo ""
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Reparar memoria corrupta (ChopperAC)"
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo ""
                    echo "  ¿Qué placa quieres diagnosticar/reparar?"
                    echo ""
                    echo "  1) L1 (slave 1)"
                    echo "  2) L2 (slave 2)"
                    echo "  3) L3 (slave 3)"
                    echo "  4) Las 3 placas (diagnóstico)"
                    echo "  0) Volver"
                    echo ""
                    read -p "  Opción [0-4]: " REPAIR_PLACA
                    
                    if [ "$REPAIR_PLACA" = "0" ]; then
                        continue
                    fi
                    
                    echo ""
                    echo "  ¿Modo?"
                    echo "  1) Solo diagnóstico (no escribe nada)"
                    echo "  2) Diagnosticar y reparar (solo corruptos)"
                    echo "  3) Guardar backup de valores actuales"
                    echo "  4) Restaurar desde backup"
                    echo ""
                    read -p "  Opción [1]: " REPAIR_MODE
                    REPAIR_MODE=${REPAIR_MODE:-1}
                    
                    echo ""
                    echo "  [!] Parando Node-RED temporalmente..."
                    sudo systemctl stop nodered 2>/dev/null
                    docker stop gesinne-rpi >/dev/null 2>&1 || true
                    sleep 2
                    echo "  [OK] Servicios parados"
                    echo ""
                    
                    if [ "$REPAIR_PLACA" = "4" ]; then
                        REPAIR_SLAVES="1 2 3"
                    else
                        REPAIR_SLAVES="$REPAIR_PLACA"
                    fi
                    
                    # Guardar script Python como archivo temporal para poder usar stdin
                    REPAIR_SCRIPT="/tmp/repair_memoria_$$.py"
                    cat > "$REPAIR_SCRIPT" << 'EOFREPAIR'
import sys
import time
import json
import os
from datetime import datetime

try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    try:
        from pymodbus.client.sync import ModbusSerialClient
    except ImportError:
        print("  [X] pymodbus no instalado")
        sys.exit(1)

# Detectar puerto serie
port = None
for p in ['/dev/ttyAMA0', '/dev/serial0', '/dev/ttyUSB0', '/dev/ttyACM0', '/dev/ttyS0']:
    if os.path.exists(p):
        port = p
        break

if not port:
    print("  [X] No se encontro puerto serie")
    sys.exit(1)

print(f"  [OK] Puerto: {port}")

MAX_RETRIES = 5

# CALIBRACION (registros 71-84): (nombre, min, max, default, signed, validacion)
CALIBRACION = {
    71: ('kV0',      25000, 35000, 30000, False, None),
    72: ('kVin',     25000, 35000, 30000, False, None),
    73: ('bV0',        -50,    50,     0,  True, None),
    74: ('bVin',       -50,    50,     0,  True, None),
    75: ('kIc',      10000, 40000, 35000, False, None),
    76: ('kIe',      10000, 40000, 35000, False, None),
    77: ('bIc',        -20,    20,     0,  True, None),
    78: ('bIe',        -20,    20,     0,  True, None),
    79: ('ruidoIc',      0,   400,     0, False, None),
    80: ('ruidoIe',      0,   400,     0, False, None),
    81: ('kP',       10000, 30000, 25000, False, None),
    82: ('bP',         -20,    20,     0,  True, None),
    83: ('Ndesfase',     0,     3,     1, False, None),
    84: ('kFrec',    32700, 32900, 32800, False, None),
}

# CONTROL (registros 91-94)
CONTROL = {
    91: ('VA',    50, 1000,  150, False, None),
    92: ('VB',     5,  200,   40, False, None),
    93: ('EMM',    2,  300,   15, False, None),
    94: ('EMMVT0', 2,  500,   15, False, None),
}

# CONFIGURACION (registros 41-67)
CONFIGURACION = {
    41: ('N.Serie',       0, 65535,     0, False, 'cualquiera'),
    42: ('Vnom',       1100,  2800,  2400, False, 'multiplo_50'),
    43: ('V prim auto', 800,  2800,  2310, False, None),
    44: ('V prim trafo',1000, 3600,  3500, False, None),
    45: ('V sec trafo',   60, 1000,   230, False, None),
    46: ('Topologia',      0,    4,     2, False, None),
    47: ('Dead-time',      3,  250,    22, False, None),
    48: ('Dir Modbus',     1,    3,     1, False, None),
    49: ('InE',           30, 2500,   400, False, None),
    50: ('InC',           15,  250,    15, False, None),
    51: ('Imax RMS',      10, None,   263, False, 'depende_InC'),
    52: ('Imax pico',     10, None,   263, False, 'depende_InC'),
    53: ('T apag CC',      1,  300,    30, False, None),
    54: ('Cnt CC',         0, 65535,    0, False, 'cualquiera'),
    55: ('Est inicial', None, None,     0, False, 'solo_0_o_2'),
    56: ('V consigna', None, None,  2400, False, 'consigna'),
    57: ('T maxima',     450,  700,   550, False, None),
    58: ('Dec T reenc',   50,  120,   100, False, None),
    59: ('Cnt ST',         0, 65535,    0, False, 'cualquiera'),
    60: ('Tipo alim',   None, None,     0, False, 'solo_0_o_1'),
    61: ('Vel RS485',   None, None,     0, False, 'solo_0_1_2'),
    62: ('Package',     None, None,     0, False, 'solo_0_o_1'),
    63: ('Ang alta',       0,  179,   179, False, None),
    64: ('Ang baja',       0,  179,   179, False, None),
    65: ('% carga',        1,   50,     5, False, None),
    66: ('Sens trans',     0,    4,     3, False, None),
    67: ('Sens deriv',     0,    6,     3, False, None),
}

PRESERVAR = {41, 48, 54, 59}  # N.Serie, Dir Modbus, contadores

BACKUP_DIR = os.path.expanduser("~/chopper_backups")

TODOS_REGISTROS = (
    list(range(71, 85)) +   # Calibracion: 71-84
    list(range(91, 95)) +   # Control: 91-94
    list(range(41, 68))      # Configuracion: 41-67
)

# Orden de escritura: InC (50) antes que Imax (51,52)
ORDEN_ESCRITURA = [
    42, 43, 44, 45, 46, 47, 48, 49,
    50,
    51, 52,
    41, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67,
    71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84,
    91, 92, 93, 94,
]


def to_signed(val):
    return val - 65536 if val > 32767 else val

def to_unsigned(val):
    return val & 0xFFFF


def leer_registro(client, reg, slave_id):
    for retry in range(MAX_RETRIES):
        try:
            time.sleep(0.08)
            resp = client.read_holding_registers(reg, 1, slave=slave_id)
            if not resp.isError():
                return resp.registers[0]
            if retry < MAX_RETRIES - 1:
                wait = 0.3 * (retry + 1)  # backoff: 0.3, 0.6, 0.9, 1.2
                time.sleep(wait)
        except Exception:
            if retry < MAX_RETRIES - 1:
                wait = 0.3 * (retry + 1)
                time.sleep(wait)
    return None


def escribir_registro(client, reg, valor, slave_id):
    for retry in range(MAX_RETRIES):
        try:
            time.sleep(0.1)
            resp = client.write_register(reg, valor, slave=slave_id)
            if not resp.isError():
                return True
            if retry < MAX_RETRIES - 1:
                wait = 0.5 * (retry + 1)  # backoff: 0.5, 1.0, 1.5, 2.0
                print(f"      [!] Reintentando reg {reg} en L{slave_id} ({retry+2}/{MAX_RETRIES})...")
                time.sleep(wait)
        except Exception as e:
            if retry < MAX_RETRIES - 1:
                wait = 0.5 * (retry + 1)
                print(f"      [!] Reintentando reg {reg} en L{slave_id} ({retry+2}/{MAX_RETRIES})...")
                time.sleep(wait)
    return False


def validar(reg, valor, definicion, config_leida):
    nombre, vmin, vmax, default, signed, validacion = definicion

    if signed:
        valor = to_signed(valor)

    if validacion == 'cualquiera':
        return True, "OK"
    if validacion == 'solo_0_o_2':
        ok = valor in (0, 2)
        return ok, "OK" if ok else f"Debe ser 0 o 2, es {valor}"
    if validacion == 'solo_0_o_1':
        ok = valor in (0, 1)
        return ok, "OK" if ok else f"Debe ser 0 o 1, es {valor}"
    if validacion == 'solo_0_1_2':
        ok = valor in (0, 1, 2)
        return ok, "OK" if ok else f"Debe ser 0, 1 o 2, es {valor}"
    if validacion == 'multiplo_50':
        if vmin is not None and vmax is not None:
            ok = vmin <= valor <= vmax and (valor % 50) == 0
            if ok:
                return True, "OK"
            if not (vmin <= valor <= vmax):
                return False, f"Fuera [{vmin}-{vmax}], es {valor}"
            return False, f"No multiplo de 50, es {valor}"
    if validacion == 'depende_InC':
        InC = config_leida.get(50, 15)
        max_perm = InC * 20
        ok = 10 <= valor <= max_perm
        return ok, f"OK (max={max_perm})" if ok else f"Fuera [10-{max_perm}], es {valor}"
    if validacion == 'consigna':
        Vnom = config_leida.get(42, 2400)
        cmin = Vnom * 80 // 100
        cmax = min(Vnom * 120 // 100, 2800)
        ok = cmin <= valor <= cmax
        return ok, f"OK ({cmin}-{cmax})" if ok else f"Fuera [{cmin}-{cmax}], es {valor}"

    if vmin is not None and vmax is not None:
        ok = vmin <= valor <= vmax
        return ok, "OK" if ok else f"Fuera [{vmin}-{vmax}], es {valor}"

    return True, "OK"


def nombre_registro(reg):
    if reg in CALIBRACION:
        return CALIBRACION[reg][0]
    elif reg in CONTROL:
        return CONTROL[reg][0]
    elif reg in CONFIGURACION:
        return CONFIGURACION[reg][0]
    return f"reg{reg}"


def activar_flags(client, slave_id):
    """Activa los 3 flags de escritura con verificacion"""
    print(f"  [~] Activando flags de escritura...")

    # Flag configuracion (reg 40 = 47818)
    escribir_registro(client, 40, 0, slave_id)
    time.sleep(0.3)
    escribir_registro(client, 40, 47818, slave_id)
    time.sleep(0.3)
    v = leer_registro(client, 40, slave_id)
    ok1 = v == 47818
    print(f"      Flag config (reg 40): escrito=47818, leido={v} {'[OK]' if ok1 else '[FALLO]'}")

    # Flag calibracion (reg 70 = 51898)
    time.sleep(0.3)
    escribir_registro(client, 70, 51898, slave_id)
    time.sleep(0.3)
    v = leer_registro(client, 70, slave_id)
    ok2 = v == 51898
    print(f"      Flag calib  (reg 70): escrito=51898, leido={v} {'[OK]' if ok2 else '[FALLO]'}")

    # Flag control (reg 90 = 56010)
    time.sleep(0.3)
    escribir_registro(client, 90, 56010, slave_id)
    time.sleep(0.3)
    v = leer_registro(client, 90, slave_id)
    ok3 = v == 56010
    print(f"      Flag control(reg 90): escrito=56010, leido={v} {'[OK]' if ok3 else '[FALLO]'}")

    time.sleep(0.5)
    return ok1 and ok2 and ok3


def desactivar_flags(client, slave_id):
    """Desactiva los 3 flags de escritura"""
    print(f"\n  [~] Desactivando flags...")
    escribir_registro(client, 40, 0, slave_id)
    time.sleep(0.1)
    escribir_registro(client, 70, 0, slave_id)
    time.sleep(0.1)
    escribir_registro(client, 90, 0, slave_id)
    time.sleep(0.1)


def verificar_alarma_mr(client, slave_id):
    """Fuerza ciclo bypass->regulacion para borrar alarma MR y verifica"""
    fase = {1: "L1", 2: "L2", 3: "L3"}.get(slave_id, f"S{slave_id}")

    # 1. Asegurar bypass
    print(f"\n  [~] Forzando bypass en {fase} (reg 31 = 0)...")
    escribir_registro(client, 31, 0, slave_id)
    time.sleep(2)

    # 2. Poner en regulacion para que re-evalúe registros
    print(f"  [~] Poniendo en regulacion {fase} (reg 31 = 2)...")
    escribir_registro(client, 31, 2, slave_id)
    time.sleep(3)

    # 3. Verificar alarma
    alarma = leer_registro(client, 2, slave_id)
    if alarma is None:
        print(f"  [!] No se pudo leer el registro de alarma")
        return

    if alarma & (1 << 10):
        # Segundo intento: ciclo bypass -> regulacion mas largo
        print(f"  [!] Alarma MR sigue activa, reintentando ciclo...")
        escribir_registro(client, 31, 0, slave_id)
        time.sleep(3)
        escribir_registro(client, 31, 2, slave_id)
        time.sleep(5)

        alarma = leer_registro(client, 2, slave_id)
        if alarma is None:
            print(f"  [!] No se pudo leer el registro de alarma")
        elif alarma & (1 << 10):
            print(f"  [!] Alarma MR SIGUE ACTIVA (reg 2 = {alarma})")
            print(f"      Puede haber un registro que no estamos cubriendo")
            print(f"      o un problema de hardware/alimentacion")
            print(f"      Prueba a apagar y encender el equipo")
        else:
            print(f"  [OK] Alarma MR BORRADA en 2o intento (reg 2 = {alarma})")
    else:
        print(f"  [OK] Alarma MR BORRADA (reg 2 = {alarma})")


def diagnosticar(client, slave_id):
    fase = {1: "L1", 2: "L2", 3: "L3"}.get(slave_id, f"S{slave_id}")
    print(f"\n{'='*75}")
    print(f"  DIAGNOSTICO MEMORIA - {fase}")
    print(f"{'='*75}")

    config_leida = {}
    corruptos = {}

    for reg in sorted(CONFIGURACION.keys()):
        val = leer_registro(client, reg, slave_id)
        if val is not None:
            config_leida[reg] = val

    # CALIBRACION
    print(f"\n  -- CALIBRACION (reg 71-84) --")
    print(f"  {'Reg':<5} {'Nombre':<12} {'Valor':<8} {'Signed':<8} {'Estado'}")
    print(f"  {'-'*65}")

    for reg in sorted(CALIBRACION.keys()):
        val = leer_registro(client, reg, slave_id)
        defn = CALIBRACION[reg]
        nombre = defn[0]
        default = defn[3]
        signed = defn[4]

        if val is None:
            print(f"  {reg:<5} {nombre:<12} {'ERR':<8} {'':<8} No se pudo leer")
            corruptos[reg] = (None, default)
            continue

        sval = to_signed(val) if signed else val
        ok, msg = validar(reg, val, defn, config_leida)
        marca = "  " if ok else ">>"
        print(f"{marca}{reg:<5} {nombre:<12} {val:<8} {sval:<8} {msg}")
        if not ok:
            corruptos[reg] = (val, default)

    # CONTROL
    print(f"\n  -- CONTROL (reg 91-94) --")
    print(f"  {'Reg':<5} {'Nombre':<12} {'Valor':<8} {'Estado'}")
    print(f"  {'-'*50}")

    for reg in sorted(CONTROL.keys()):
        val = leer_registro(client, reg, slave_id)
        defn = CONTROL[reg]
        nombre = defn[0]
        default = defn[3]

        if val is None:
            print(f"  {reg:<5} {nombre:<12} {'ERR':<8} No se pudo leer")
            corruptos[reg] = (None, default)
            continue

        ok, msg = validar(reg, val, defn, config_leida)
        marca = "  " if ok else ">>"
        print(f"{marca}{reg:<5} {nombre:<12} {val:<8} {msg}")
        if not ok:
            corruptos[reg] = (val, default)

    # CONFIGURACION
    print(f"\n  -- CONFIGURACION (reg 41-67) --")
    print(f"  {'Reg':<5} {'Nombre':<12} {'Valor':<8} {'Estado'}")
    print(f"  {'-'*50}")

    for reg in sorted(CONFIGURACION.keys()):
        val = config_leida.get(reg)
        defn = CONFIGURACION[reg]
        nombre = defn[0]
        default = defn[3]

        if val is None:
            print(f"  {reg:<5} {nombre:<12} {'ERR':<8} No se pudo leer")
            corruptos[reg] = (None, default)
            continue

        ok, msg = validar(reg, val, defn, config_leida)
        marca = "  " if ok else ">>"
        print(f"{marca}{reg:<5} {nombre:<12} {val:<8} {msg}")
        if not ok:
            corruptos[reg] = (val, default)

    # FW VERSION
    print(f"\n  -- INFO FW --")
    fw = leer_registro(client, 100, slave_id)
    alarma = leer_registro(client, 2, slave_id)
    estado = leer_registro(client, 0, slave_id)
    print(f"  FW Version: {fw}")
    print(f"  Alarma:     {alarma} (bit10 MR = {1 if alarma and alarma & (1<<10) else 0})")
    print(f"  Estado:     {estado}")

    # RESUMEN
    print(f"\n{'='*75}")
    if corruptos:
        print(f"  [!] {len(corruptos)} PARAMETROS FUERA DE RANGO:")
        for reg, (val_act, val_def) in sorted(corruptos.items()):
            nombre = nombre_registro(reg)
            print(f"      Reg {reg:>3} ({nombre:<12}): actual={val_act}, default={val_def}")
    else:
        print(f"  [OK] Todos los parametros dentro de rango")
    print(f"{'='*75}")

    return corruptos


def reparar(client, slave_id, corruptos):
    if not corruptos:
        print("\n  [OK] No hay nada que reparar")
        return

    fase = {1: "L1", 2: "L2", 3: "L3"}.get(slave_id, f"S{slave_id}")
    print(f"\n{'='*75}")
    print(f"  REPARACION MEMORIA - {fase}")
    print(f"{'='*75}")

    regs_a_reparar = {r: v for r, v in corruptos.items() if r not in PRESERVAR}
    regs_preservados = {r: v for r, v in corruptos.items() if r in PRESERVAR}

    print(f"\n  Se van a reparar {len(regs_a_reparar)} registros:")
    for reg, (val_act, val_def) in sorted(regs_a_reparar.items()):
        print(f"    Reg {reg:>3}: {val_act} -> {val_def}")
    if regs_preservados:
        print(f"\n  Se preservan {len(regs_preservados)} registros:")
        for reg, (val_act, val_def) in sorted(regs_preservados.items()):
            print(f"    Reg {reg:>3}: {val_act} (no se toca)")

    if not regs_a_reparar:
        print("\n  [OK] Solo hay registros preservados, nada que reparar")
        return

    print("")
    resp = input("  Confirmar reparacion? (s/N): ").strip().lower()
    if resp != 's':
        print("  [X] Cancelado por el usuario")
        return

    # 1. Poner en bypass
    estado = leer_registro(client, 0, slave_id)
    if estado and estado != 0:
        print(f"\n  [~] Poniendo en bypass...")
        escribir_registro(client, 31, 0, slave_id)
        time.sleep(2)

    # 2. Activar flags
    if not activar_flags(client, slave_id):
        print("  [!] ATENCION: Algun flag no se activo correctamente")

    # 3. Escribir valores (en orden correcto)
    ok_count = 0
    err_count = 0

    for reg in ORDEN_ESCRITURA:
        if reg not in regs_a_reparar:
            continue
        val_act, val_def = regs_a_reparar[reg]

        signed = False
        if reg in CALIBRACION:
            signed = CALIBRACION[reg][4]

        valor_escribir = to_unsigned(val_def) if signed and val_def < 0 else val_def

        print(f"  [~] Reg {reg:>3}: {val_act} -> {val_def}...", end=" ", flush=True)
        if escribir_registro(client, reg, valor_escribir, slave_id):
            time.sleep(0.1)
            leido = leer_registro(client, reg, slave_id)
            if leido == valor_escribir:
                print("[OK]")
                ok_count += 1
            else:
                print(f"[!] Verificacion fallo: leido={leido}")
                err_count += 1
        else:
            print("[X] Error escritura")
            err_count += 1

    # 4. Desactivar flags
    desactivar_flags(client, slave_id)

    # 5. Resumen
    print(f"\n{'='*75}")
    print(f"  RESULTADO: {ok_count} reparados, {err_count} errores")
    if err_count == 0:
        print(f"  [OK] Reparacion completada")
        verificar_alarma_mr(client, slave_id)
    else:
        print(f"  [!] Hubo errores. Revisar manualmente")
    print(f"{'='*75}")


def backup_registros(client, slave_id):
    """Lee todos los registros y los guarda en un fichero JSON"""
    print(f"\n{'='*75}")
    print(f"  BACKUP REGISTROS - L{slave_id}")
    print(f"{'='*75}")

    datos = {}
    errores = 0

    for reg in TODOS_REGISTROS:
        val = leer_registro(client, reg, slave_id)
        nombre = nombre_registro(reg)
        if val is None:
            print(f"  [X] Reg {reg:>3} ({nombre}): no se pudo leer")
            errores += 1
        else:
            datos[str(reg)] = val
            signed = False
            if reg in CALIBRACION:
                signed = CALIBRACION[reg][4]
            sval = to_signed(val) if signed else val
            extra = f" (signed={sval})" if signed and sval < 0 else ""
            print(f"  [OK] Reg {reg:>3} ({nombre:<12}): {val}{extra}")

    if errores:
        print(f"\n  [!] {errores} registros no se pudieron leer")
        resp = input("  Guardar backup parcial? (s/N): ").strip().lower()
        if resp != 's':
            print("  Cancelado")
            return None

    fw = leer_registro(client, 100, slave_id)
    alarma = leer_registro(client, 2, slave_id)
    nserie = leer_registro(client, 41, slave_id)

    os.makedirs(BACKUP_DIR, exist_ok=True)

    fecha = datetime.now().strftime("%Y%m%d_%H%M%S")
    sn = nserie if nserie else 0
    filename = f"chopper_L{slave_id}_SN{sn}_{fecha}.json"
    filepath = os.path.join(BACKUP_DIR, filename)

    backup = {
        "info": {
            "slave_id": slave_id,
            "numero_serie": nserie,
            "fw_version": fw,
            "alarma": alarma,
            "fecha": datetime.now().isoformat(),
            "registros_leidos": len(datos),
            "registros_error": errores,
        },
        "registros": datos,
    }

    with open(filepath, 'w') as f:
        json.dump(backup, f, indent=2)

    print(f"\n{'='*75}")
    print(f"  [OK] Backup guardado: {filepath}")
    print(f"       {len(datos)} registros, SN={sn}, FW={fw}")
    print(f"{'='*75}")
    return filepath


def buscar_ultimo_backup(slave_id):
    """Busca el backup mas reciente para un slave_id"""
    if not os.path.exists(BACKUP_DIR):
        return None
    archivos = []
    for f in os.listdir(BACKUP_DIR):
        if f.startswith(f"chopper_L{slave_id}_") and f.endswith(".json"):
            archivos.append(os.path.join(BACKUP_DIR, f))
    if not archivos:
        return None
    archivos.sort()
    return archivos[-1]


def restaurar_desde_backup(client, slave_id, filepath=None):
    """Restaura todos los registros desde un fichero de backup"""
    if filepath is None:
        filepath = buscar_ultimo_backup(slave_id)
        if filepath is None:
            print(f"\n  [X] No hay backups para L{slave_id} en {BACKUP_DIR}")
            print(f"      Primero haz un backup con la opcion 3")
            return

    if not os.path.exists(filepath):
        print(f"\n  [X] Fichero no encontrado: {filepath}")
        return

    with open(filepath, 'r') as f:
        backup = json.load(f)

    info = backup.get("info", {})
    registros = backup.get("registros", {})

    print(f"\n{'='*75}")
    print(f"  RESTAURAR DESDE BACKUP - L{slave_id}")
    print(f"{'='*75}")
    print(f"  Fichero:   {os.path.basename(filepath)}")
    print(f"  Fecha:     {info.get('fecha', '?')}")
    print(f"  SN:        {info.get('numero_serie', '?')}")
    print(f"  FW:        {info.get('fw_version', '?')}")
    print(f"  Registros: {len(registros)}")

    # Comparar con valores actuales
    print(f"\n  Comparacion backup vs actual:")
    print(f"  {'Reg':<5} {'Nombre':<12} {'Backup':<8} {'Actual':<8} {'Estado'}")
    print(f"  {'-'*55}")

    diferentes = {}
    for reg in ORDEN_ESCRITURA:
        reg_str = str(reg)
        if reg_str not in registros:
            continue

        val_backup = registros[reg_str]
        val_actual = leer_registro(client, reg, slave_id)
        nombre = nombre_registro(reg)

        if val_actual is None:
            print(f">>{reg:<5} {nombre:<12} {val_backup:<8} {'ERR':<8} No se pudo leer")
            diferentes[reg] = val_backup
        elif val_actual != val_backup:
            print(f">>{reg:<5} {nombre:<12} {val_backup:<8} {val_actual:<8} DIFERENTE")
            diferentes[reg] = val_backup
        else:
            print(f"  {reg:<5} {nombre:<12} {val_backup:<8} {val_actual:<8} OK")

    if not diferentes:
        print(f"\n  [OK] Todos los registros coinciden con el backup")
        return

    print(f"\n  [!] {len(diferentes)} registros diferentes")

    resp = input("\n  Restaurar estos registros? (s/N): ").strip().lower()
    if resp != 's':
        print("  Cancelado")
        return

    # 1. Poner en bypass
    estado = leer_registro(client, 0, slave_id)
    if estado and estado != 0:
        print(f"\n  [~] Poniendo en bypass...")
        escribir_registro(client, 31, 0, slave_id)
        time.sleep(2)

    # 2. Activar flags
    if not activar_flags(client, slave_id):
        print("  [!] ATENCION: Algun flag no se activo correctamente")

    # 3. Escribir en orden correcto
    ok_count = 0
    err_count = 0

    for reg in ORDEN_ESCRITURA:
        if reg not in diferentes:
            continue

        valor = diferentes[reg]
        nombre = nombre_registro(reg)

        print(f"  [~] Reg {reg:>3} ({nombre:<12}): -> {valor}...", end=" ", flush=True)
        if escribir_registro(client, reg, valor, slave_id):
            time.sleep(0.1)
            leido = leer_registro(client, reg, slave_id)
            if leido == valor:
                print("[OK]")
                ok_count += 1
            else:
                print(f"[!] Verificacion: leido={leido}")
                err_count += 1
        else:
            print("[X] Error escritura")
            err_count += 1

    # 4. Desactivar flags
    desactivar_flags(client, slave_id)

    # 5. Verificar alarma MR
    print(f"\n{'='*75}")
    print(f"  RESULTADO: {ok_count} restaurados, {err_count} errores")
    if err_count == 0:
        print(f"  [OK] Restauracion completada desde backup")
        verificar_alarma_mr(client, slave_id)
    else:
        print(f"  [!] Hubo errores. Revisar manualmente")
    print(f"{'='*75}")


# --- MAIN ---
if len(sys.argv) < 3:
    print("Uso: repair_script.py <slaves> <mode>")
    sys.exit(1)

slaves_str = sys.argv[1]
mode = sys.argv[2]  # "diag", "fix", "backup", "restore"

client = ModbusSerialClient(
    port=port, baudrate=115200,
    bytesize=8, parity='N', stopbits=1, timeout=3
)

if not client.connect():
    print("  [X] No se pudo conectar al puerto serie")
    sys.exit(1)

try:
    slaves = [int(x) for x in slaves_str.split()]

    for slave_id in slaves:
        if mode == "backup":
            backup_registros(client, slave_id)
        elif mode == "restore":
            restaurar_desde_backup(client, slave_id)
        else:
            corruptos = diagnosticar(client, slave_id)
            if mode == "fix":
                reparar(client, slave_id, corruptos)
            elif corruptos:
                fase = {1: "L1", 2: "L2", 3: "L3"}.get(slave_id, f"S{slave_id}")
                print(f"\n  Para reparar {fase}, usa el modo 'Diagnosticar y reparar'")
finally:
    client.close()
    print(f"\n  Conexion cerrada")
EOFREPAIR
                    
                    REPAIR_FIX="diag"
                    if [ "$REPAIR_MODE" = "2" ]; then
                        REPAIR_FIX="fix"
                    elif [ "$REPAIR_MODE" = "3" ]; then
                        REPAIR_FIX="backup"
                    elif [ "$REPAIR_MODE" = "4" ]; then
                        REPAIR_FIX="restore"
                    fi
                    
                    # Ejecutar como archivo (no heredoc) para que input() funcione
                    python3 "$REPAIR_SCRIPT" "$REPAIR_SLAVES" "$REPAIR_FIX"
                    rm -f "$REPAIR_SCRIPT"
                    
                    echo ""
                    echo "  [~] Reiniciando Node-RED..."
                    sudo systemctl start nodered
                    docker start gesinne-rpi 2>/dev/null || true
                    sleep 3
                    echo "  [OK] Servicios reiniciados"
                    
                    volver_menu
                    continue
                    ;;
                *) echo "  [X] Opción no válida"; continue ;;
            esac
            
            # Siempre detectar el máximo de registros
            NUM_REGS=200
            DETECT_MAX="yes"
            
            echo ""
            echo "  [!]  Parando Node-RED temporalmente..."
            
            # Parar Node-RED
            sudo systemctl stop nodered 2>/dev/null
            
            # Parar contenedor Docker si existe (silencioso)
            docker stop gesinne-rpi >/dev/null 2>&1 || true
            
            sleep 2
            echo "  [OK] Servicios parados"
            echo ""
            
            # Detectar puerto serie automáticamente
            echo "  [~] Detectando puerto serie..."
            SERIAL_PORT=""
            for port in /dev/ttyAMA0 /dev/serial0 /dev/ttyUSB0 /dev/ttyACM0 /dev/ttyS0; do
                if [ -e "$port" ]; then
                    SERIAL_PORT="$port"
                    echo "  [OK] Puerto encontrado: $SERIAL_PORT"
                    break
                fi
            done
            
            if [ -z "$SERIAL_PORT" ]; then
                echo "  [X] No se encontró ningún puerto serie"
                echo "      Puertos buscados: /dev/ttyAMA0, /dev/serial0, /dev/ttyUSB0, /dev/ttyACM0, /dev/ttyS0"
                volver_menu
                continue
            fi
            echo ""
            
            # Si es modo columnas, leer las 3 placas y mostrar en tabla
            if [ "$MODO_COLUMNAS" = "yes" ]; then
                echo "  [M] Leyendo las 3 tarjetas..."
                echo ""
                
                python3 << EOFCOL
import sys
import time

try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    try:
        from pymodbus.client.sync import ModbusSerialClient
    except ImportError:
        print("  [X] pymodbus no instalado")
        sys.exit(1)

PUERTO = "$SERIAL_PORT"
BAUDRATES = [115200, 57600, 9600]

client = None
connected = False

for baudrate in BAUDRATES:
    try:
        client = ModbusSerialClient(
            port=PUERTO,
            baudrate=baudrate,
            bytesize=8,
            parity='N',
            stopbits=1,
            timeout=2
        )
        
        if client.connect():
            result = client.read_holding_registers(address=0, count=1, slave=1)
            if not result.isError():
                print(f"  [OK] Conectado a {PUERTO} @ {baudrate} baud")
                connected = True
                break
            client.close()
    except Exception as e:
        if client:
            client.close()
        continue

if not connected:
    print(f"  [X] No se pudo comunicar con las placas")
    print(f"      Puerto: {PUERTO}")
    print(f"      Baudrates probados: {BAUDRATES}")
    sys.exit(1)

# Leer las 3 placas con reintentos
data_all = {}
for unit_id in [1, 2, 3]:
    fase = {1: "L1", 2: "L2", 3: "L3"}[unit_id]
    print(f"  [M] Leyendo tarjeta {fase}...", end=" ", flush=True)
    
    data = [None] * 112
    max_retries = 3
    success = False
    
    for retry in range(max_retries):
        # Leer registros 0-95 (existen todos)
        temp_data = []
        ok = True
        for start in range(0, 96, 40):
            count = min(40, 96 - start)
            result = client.read_holding_registers(address=start, count=count, slave=unit_id)
            if result.isError():
                ok = False
                break
            temp_data.extend(result.registers)
        
        if ok and len(temp_data) >= 96:
            for i in range(96):
                data[i] = temp_data[i]
            
            # Leer registros 100-107 (INFO FW)
            result = client.read_holding_registers(address=100, count=8, slave=unit_id)
            if not result.isError():
                for i, val in enumerate(result.registers):
                    data[100 + i] = val
            
            # Leer registros 110-111 (RESET)
            result = client.read_holding_registers(address=110, count=2, slave=unit_id)
            if not result.isError():
                data[110] = result.registers[0]
                data[111] = result.registers[1]
            
            success = True
            print("[OK]")
            break
        else:
            if retry < max_retries - 1:
                print(f"[!] reintentando ({retry+2}/{max_retries})...", end=" ", flush=True)
                time.sleep(1)
            else:
                print("[X] sin respuesta")
    
    data_all[unit_id] = data if success else None

client.close()

# Verificar que las 3 placas respondieron
placas_ok = [u for u in [1, 2, 3] if data_all[u] is not None]
placas_fail = [u for u in [1, 2, 3] if data_all[u] is None]

if placas_fail:
    print("")
    print(f"  [!]  No se pudo leer: {', '.join(['L'+str(u) for u in placas_fail])}")
    if not placas_ok:
        print("  [X] No hay datos para mostrar")
        sys.exit(1)

# Rellenar placas sin datos con lista de None para mostrar "---"
for u in placas_fail:
    data_all[u] = [None] * 112

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
    90: "Flag Ctrl", 91: "Cn00", 92: "Cn01", 93: "Cn02", 94: "Cn03", 95: "ReCn", 96: "Cn05",
    100: "Versión FW", 101: "Tipo FW", 102: "Microproc", 103: "FLASH rest",
    104: "Frec PWM", 105: "Mando apag", 106: "Mando mín", 107: "Mando máx",
    110: "Flag Reset", 111: "RESET FW"
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
            diff = "[!] DIFF" if len(vals) >= 2 and len(set(vals)) > 1 else ""
            
            print(f"  {i:<4} {regs[i]:<14} {s1} {s2} {s3}   {diff}")

print_section("TIEMPO REAL", 0, 22)
print_section("ESTADO", 30, 35)
print_section("CONFIGURACIÓN", 40, 70)
print_section("CALIBRACIÓN", 70, 87)
print_section("CONTROL", 90, 97)
print_section("INFO FW", 100, 112)

print("")
EOFCOL
                
                # Reiniciar servicios
                echo ""
                read -p "  ¿Reiniciar servicios ahora? [y/N]: " CONFIRMAR_RESTART
                if [[ "$CONFIRMAR_RESTART" =~ ^[Yy]$ ]]; then
                    echo "  [~] Reiniciando servicios..."
                    sudo systemctl start nodered
                    docker start gesinne-rpi 2>/dev/null || true
                    if systemctl is-active --quiet kiosk.service 2>/dev/null; then
                        sudo systemctl restart kiosk.service
                    fi
                    echo "  [OK] Listo"
                else
                    echo "  [!] Servicios NO reiniciados. Recuerda iniciarlos manualmente:"
                    echo "      sudo systemctl start nodered"
                fi
                
                volver_menu
                continue
            fi
            
            # Modo normal: una placa a la vez (SERIAL_PORT ya detectado arriba)
            for UNIT_ID in $UNIT_IDS; do
            
            case $UNIT_ID in
                1) FASE="L1" ;;
                2) FASE="L2" ;;
                3) FASE="L3" ;;
            esac
            
            echo "  [M] Leyendo registros de Tarjeta $FASE (Unit ID: $UNIT_ID)..."
            echo ""
            
            python3 << EOF
import sys
import os
import glob

try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    try:
        from pymodbus.client.sync import ModbusSerialClient
    except ImportError:
        print("  [X] pymodbus no instalado. Instala con: pip3 install pymodbus")
        sys.exit(1)

# Puerto detectado por bash
PUERTO = "$SERIAL_PORT"

# Probar diferentes baudrates si falla
BAUDRATES = [115200, 57600, 9600]

client = None
connected = False

for baudrate in BAUDRATES:
    try:
        client = ModbusSerialClient(
            port=PUERTO,
            baudrate=baudrate,
            bytesize=8,
            parity='N',
            stopbits=1,
            timeout=2
        )
        
        if client.connect():
            # Probar lectura rápida para verificar comunicación
            result = client.read_holding_registers(address=0, count=1, slave=$UNIT_ID)
            if not result.isError():
                print(f"  [OK] Conectado a {PUERTO} @ {baudrate} baud")
                connected = True
                break
            client.close()
    except Exception as e:
        if client:
            client.close()
        continue

if not connected:
    print(f"  [X] No se pudo comunicar con la placa $FASE (Unit ID: $UNIT_ID)")
    print(f"      Puerto: {PUERTO}")
    print(f"      Baudrates probados: {BAUDRATES}")
    print("")
    print("  Posibles causas:")
    print("      • La placa no está conectada o alimentada")
    print("      • El Unit ID ($UNIT_ID) no coincide con la dirección Modbus de la placa")
    print("      • El cable serie está desconectado o dañado")
    print("      • Otro proceso está usando el puerto serie")
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
        
        print(f"  [OK] Máximo detectado: {max_reg} registros")
        print("")
        num_regs = max_reg
    
    # Leer los registros
    data = []
    # Leer en bloques de 40 para mayor compatibilidad
    for start in range(0, num_regs, 40):
        count = min(40, num_regs - start)
        result = client.read_holding_registers(address=start, count=count, slave=$UNIT_ID)
        if result.isError():
            print(f"  [!]  Error en registros {start}-{start+count-1}")
            break
        data.extend(result.registers)
    
    if data:
        print(f"  [i] Registros Tarjeta $FASE (0-{len(data)-1}):")
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
            for i in range(90, 112):
                if i in regs and i < len(data):
                    desc, nombre = regs[i]
                    print(f"  {i:3d} | {nombre:24s} | {data[i]:10d} | {desc}")
        
        print("")
    else:
        print("  [X] No se pudieron leer registros")
    
except Exception as e:
    print(f"  [X] Error: {e}")
finally:
    client.close()
EOF
            
            done  # fin del bucle for UNIT_ID
            
            # Guardar automáticamente en archivo
            ARCHIVO="/home/$(logname 2>/dev/null || echo 'pi')/parametros_configuracion.txt"
            echo ""
            echo "  [D] Guardando en: $ARCHIVO"
            
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
    for start in range(0, 112, 40):
        count = min(40, 112 - start)
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
            echo "  [OK] Archivo guardado: $ARCHIVO"
            
            echo ""
            read -p "  ¿Reiniciar servicios ahora? [y/N]: " CONFIRMAR_RESTART
            if [[ "$CONFIRMAR_RESTART" =~ ^[Yy]$ ]]; then
                echo "  [~] Reiniciando servicios..."
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
                
                echo "  [OK] Listo"
            else
                echo "  [!] Servicios NO reiniciados. Recuerda iniciarlos manualmente:"
                echo "      sudo systemctl start nodered"
            fi
            
            volver_menu
            ;;
        5)
            # Revisar espacio y logs
            echo ""
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Revisar espacio y logs"
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
            # Espacio en disco
            echo "  [#] ESPACIO EN DISCO"
            echo "  ─────────────────────────────────────────────"
            df -h / | awk 'NR==1 {print "  " $0} NR==2 {print "  " $0}'
            echo ""
            
            # Uso por directorio
            echo "  [F] USO POR DIRECTORIO (top 10)"
            echo "  ─────────────────────────────────────────────"
            du -sh /var/log /var/cache /tmp /home/*/.node-red /var/lib/docker 2>/dev/null | sort -rh | head -10 | while read line; do
                echo "  $line"
            done
            echo ""
            
            # Logs más grandes
            echo "  [L] LOGS MÁS GRANDES"
            echo "  ─────────────────────────────────────────────"
            find /var/log -type f -exec du -sh {} \; 2>/dev/null | sort -rh | head -5 | while read line; do
                echo "  $line"
            done
            echo ""
            
            # Journal systemd
            echo "  [J] JOURNAL SYSTEMD"
            echo "  ─────────────────────────────────────────────"
            journalctl --disk-usage 2>/dev/null | sed 's/^/  /'
            echo ""
            
            # Opciones de limpieza
            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ¿Quieres limpiar espacio?"
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
                    echo "  [C] Limpiando journal systemd..."
                    sudo journalctl --vacuum-time=3d
                    sudo journalctl --vacuum-size=100M
                    echo "  [OK] Journal limpiado"
                    ;;
                2)
                    echo ""
                    echo "  [C] Limpiando logs en /var/log..."
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
                    echo "  [OK] Logs limpiados"
                    ;;
                3)
                    echo ""
                    echo "  [C] Limpiando caché apt..."
                    sudo apt-get clean
                    sudo apt-get autoremove -y
                    echo "  [OK] Caché apt limpiada"
                    ;;
                4)
                    echo ""
                    echo "  [C] Limpiando Docker..."
                    docker system prune -f --filter "until=24h" 2>/dev/null || echo "  [!] Docker no disponible"
                    echo "  [OK] Docker limpiado"
                    ;;
                5)
                    echo ""
                    echo "  [C] Limpiando TODO..."
                    echo ""
                    sudo journalctl --vacuum-time=3d 2>/dev/null
                    sudo journalctl --vacuum-size=100M 2>/dev/null
                    sudo logrotate -f /etc/logrotate.conf 2>/dev/null || true
                    sudo find /var/log -type f -name "*.gz" -delete 2>/dev/null
                    sudo find /var/log -type f -name "*.1" -delete 2>/dev/null
                    sudo find /var/log -type f -name "*.old" -delete 2>/dev/null
                    sudo apt-get clean 2>/dev/null
                    sudo apt-get autoremove -y 2>/dev/null
                    docker system prune -f 2>/dev/null || true
                    echo "  [OK] Todo limpiado"
                    ;;
                6)
                    echo ""
                    echo "  [C] Configurando reducción permanente de logs..."
                    # Reducir journal permanentemente
                    sudo mkdir -p /etc/systemd/journald.conf.d/
                    echo -e "[Journal]\nSystemMaxUse=50M\nMaxRetentionSec=3days" | sudo tee /etc/systemd/journald.conf.d/size.conf > /dev/null
                    sudo systemctl restart systemd-journald
                    echo "  [OK] Journal configurado para máximo 50MB y 3 días"
                    ;;
                0|*)
                    echo "  Volviendo al menú..."
                    ;;
            esac
            
            volver_menu
            ;;
        6)
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
                echo "  [X] No se encontró directorio .node-red"
                volver_menu
                continue
            fi
            
            MODULES_DIR="$NODERED_DIR/node_modules"
            
            echo "  [P] NODOS INSTALADOS"
            echo "  ─────────────────────────────────────────────"
            echo ""
            
            # Listar nodos node-red instalados con versiones
            if [ -d "$MODULES_DIR" ]; then
                cd "$NODERED_DIR"
                
                # Usar npm ls para obtener los nodos instalados (solo dependencias directas)
                echo "  Cargando lista de nodos y comprobando actualizaciones..."
                echo ""
                
                # Obtener nodos instalados y comprobar actualizaciones
                npm ls --depth=0 --json 2>/dev/null | python3 -c "
import json, sys, subprocess

def get_latest_version(pkg_name):
    try:
        result = subprocess.run(['npm', 'view', pkg_name, 'version'], 
                              capture_output=True, text=True, timeout=10)
        return result.stdout.strip() if result.returncode == 0 else None
    except:
        return None

try:
    data = json.load(sys.stdin)
    deps = data.get('dependencies', {})
    for name, info in sorted(deps.items()):
        version = info.get('version', '?')
        # Mostrar solo nodos de Node-RED (excluir dependencias internas)
        if 'node-red' in name or name.startswith('@') or name in ['guaranteed-delivery', 'modbus-serial']:
            latest = get_latest_version(name)
            if latest and latest != version:
                print(f'  {name:<42} v{version:<10} → v{latest} [^]')
            else:
                print(f'  {name:<42} v{version:<10} [OK]')
except Exception as e:
    pass
" 2>/dev/null
                
                cd - > /dev/null
            else
                echo "  [X] No existe directorio node_modules"
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
            echo "  5) Verificar/Corregir permisos"
            echo "  6) Limpiar caché npm (si falla actualización)"
            echo "  0) Volver al menú"
            echo ""
            read -p "  Opción [0-6]: " PALETTE_OPT
            
            case $PALETTE_OPT in
                1)
                    echo ""
                    echo "  [~] Actualizando todos los nodos..."
                    cd "$NODERED_DIR"
                    npm update 2>&1 | sed 's/^/  /'
                    cd - > /dev/null
                    echo ""
                    echo "  [~] Reiniciando Node-RED..."
                    sudo systemctl restart nodered
                    echo "  [OK] Listo"
                    ;;
                2)
                    echo ""
                    read -p "  Nombre del nodo a actualizar: " NODE_NAME
                    if [ -n "$NODE_NAME" ]; then
                        cd "$NODERED_DIR"
                        npm update "$NODE_NAME" 2>&1 | sed 's/^/  /'
                        cd - > /dev/null
                        echo ""
                        echo "  [~] Reiniciando Node-RED..."
                        sudo systemctl restart nodered
                        echo "  [OK] Listo"
                    fi
                    ;;
                3)
                    echo ""
                    echo "  Nodos recomendados:"
                    echo "    - node-red-contrib-modbus"
                    echo "    - node-red-dashboard"
                    echo "    - node-red-contrib-azure-iot-hub"
                    echo ""
                    read -p "  Nombre del nodo a instalar: " NODE_NAME
                    if [ -n "$NODE_NAME" ]; then
                        cd "$NODERED_DIR"
                        npm install "$NODE_NAME" 2>&1 | sed 's/^/  /'
                        cd - > /dev/null
                        echo ""
                        echo "  [~] Reiniciando Node-RED..."
                        sudo systemctl restart nodered
                        echo "  [OK] Listo"
                    fi
                    ;;
                4)
                    echo ""
                    read -p "  Nombre del nodo a desinstalar: " NODE_NAME
                    if [ -n "$NODE_NAME" ]; then
                        read -p "  ¿Seguro que quieres desinstalar $NODE_NAME? [y/N]: " CONFIRM
                        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                            cd "$NODERED_DIR"
                            npm uninstall "$NODE_NAME" 2>&1 | sed 's/^/  /'
                            cd - > /dev/null
                            echo ""
                            echo "  [~] Reiniciando Node-RED..."
                            sudo systemctl restart nodered
                            echo "  [OK] Listo"
                        else
                            echo "  [X] Cancelado"
                        fi
                    fi
                    ;;
                5)
                    echo ""
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Verificar permisos de Node-RED"
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo ""
                    
                    # Detectar usuario de Node-RED
                    NODERED_USER=$(stat -c '%U' "$NODERED_DIR" 2>/dev/null)
                    echo "  [U] Usuario Node-RED: $NODERED_USER"
                    echo ""
                    
                    # Verificar permisos
                    echo "  [P] Verificando permisos..."
                    PERM_ISSUES=0
                    
                    # Verificar node_modules
                    if [ -d "$MODULES_DIR" ]; then
                        BAD_PERMS=$(find "$MODULES_DIR" ! -user "$NODERED_USER" 2>/dev/null | wc -l)
                        if [ "$BAD_PERMS" -gt 0 ]; then
                            echo "  [!] $BAD_PERMS archivos con permisos incorrectos en node_modules"
                            PERM_ISSUES=1
                        else
                            echo "  [OK] node_modules: permisos correctos"
                        fi
                    fi
                    
                    # Verificar flows.json
                    FLOWS_FILE="$NODERED_DIR/flows.json"
                    if [ -f "$FLOWS_FILE" ]; then
                        FLOWS_OWNER=$(stat -c '%U' "$FLOWS_FILE" 2>/dev/null)
                        if [ "$FLOWS_OWNER" != "$NODERED_USER" ]; then
                            echo "  [!] flows.json: propietario incorrecto ($FLOWS_OWNER)"
                            PERM_ISSUES=1
                        else
                            echo "  [OK] flows.json: permisos correctos"
                        fi
                    fi
                    
                    echo ""
                    if [ "$PERM_ISSUES" -eq 1 ]; then
                        read -p "  ¿Corregir permisos? [Y/n]: " FIX_PERMS
                        if [[ ! "$FIX_PERMS" =~ ^[Nn]$ ]]; then
                            echo ""
                            echo "  [~] Corrigiendo permisos..."
                            sudo chown -R "$NODERED_USER:$NODERED_USER" "$NODERED_DIR"
                            echo "  [OK] Permisos corregidos"
                            echo ""
                            echo "  [~] Reiniciando Node-RED..."
                            sudo systemctl restart nodered
                            echo "  [OK] Listo"
                        fi
                    else
                        echo "  [OK] Todos los permisos son correctos"
                    fi
                    ;;
                6)
                    echo ""
                    echo "  [C] Limpiando caché npm..."
                    npm cache clean --force 2>&1 | sed 's/^/  /'
                    echo "  [OK] Caché limpiada"
                    ;;
                0|*)
                    echo "  Volviendo al menú..."
                    ;;
            esac
            
            volver_menu
            ;;
        p|P)
            # Opción oculta - Modo Patry
            PATRY_SCRIPT="/tmp/oculto_patry.sh"
            curl -sSL "https://raw.githubusercontent.com/Gesinne/rpi-azure-bridge/main/oculto_patry.sh" -o "$PATRY_SCRIPT" 2>/dev/null
            
            if [ -f "$PATRY_SCRIPT" ]; then
                chmod +x "$PATRY_SCRIPT"
                bash "$PATRY_SCRIPT"
            else
                echo "  [X] Error descargando script"
            fi
            
            volver_menu
            ;;
        *)
            # Opción no válida, volver al menú
            ;;
    esac
done
