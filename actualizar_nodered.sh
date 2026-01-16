#!/bin/bash
#
# Script para actualizar Node-RED Core
# Verifica versión antes de actualizar para evitar descargas innecesarias
#

set -e

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Actualizar Node-RED Core"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Verificar que Node-RED está instalado
if ! command -v node-red &> /dev/null; then
    echo "  [X] Node-RED no está instalado"
    exit 1
fi

# Verificar si hay actualización de npm disponible
echo "  [~] Comprobando versiones..."
echo ""

CURRENT_NPM=$(npm --version 2>/dev/null || echo "0.0.0")
LATEST_NPM=$(npm view npm version 2>/dev/null || echo "?")

if [ "$CURRENT_NPM" != "$LATEST_NPM" ] && [ "$LATEST_NPM" != "?" ]; then
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │  npm actual:   $CURRENT_NPM"
    echo "  │  npm última:   $LATEST_NPM"
    echo "  └─────────────────────────────────────────┘"
    echo ""
    read -p "  ¿Actualizar npm primero? [S/n]: " UPDATE_NPM
    if [ "$UPDATE_NPM" != "n" ] && [ "$UPDATE_NPM" != "N" ]; then
        echo ""
        echo "  [~] Actualizando npm..."
        sudo npm install -g --no-audit --no-fund --progress=false --loglevel=error npm@latest 2>&1 | grep -E '(added|removed|changed|npm@)' || true
        echo "  [OK] npm actualizado a $(npm --version)"
        echo ""
    fi
fi

# Obtener versión actual
CURRENT_VERSION=$(node-red --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")

# Obtener última versión disponible (rápido, solo metadata)
LATEST_VERSION=$(npm view node-red version 2>/dev/null || echo "?")

echo "  ┌─────────────────────────────────────────┐"
echo "  │  Versión actual:   $CURRENT_VERSION"
echo "  │  Última versión:   $LATEST_VERSION"
echo "  └─────────────────────────────────────────┘"
echo ""

# Comparar versiones
if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    echo "  [OK] Node-RED ya está en la última versión"
    echo ""
    read -p "  ¿Reinstalar de todos modos? [s/N]: " FORCE_UPDATE
    if [[ ! "$FORCE_UPDATE" =~ ^[Ss]$ ]]; then
        echo ""
        echo "  [OK] Sin cambios"
        exit 0
    fi
else
    echo "  [!] Hay una nueva versión disponible"
fi

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Advertencia"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  La actualización puede tardar varios minutos"
echo "  en conexiones lentas (descarga ~50-100MB)"
echo ""
read -p "  ¿Continuar con la actualización? [S/n]: " DO_UPDATE

if [ "$DO_UPDATE" = "n" ] || [ "$DO_UPDATE" = "N" ]; then
    echo ""
    echo "  [X] Actualización cancelada"
    exit 0
fi

echo ""
echo "  [~] Preparando descarga (sin parar Node-RED)..."
echo ""

TMP_DIR="/tmp/nodered_update_$$"
mkdir -p "$TMP_DIR"
NODERED_TGZ=""

if [ "$LATEST_VERSION" != "?" ]; then
    if npm pack "node-red@$LATEST_VERSION" --silent --pack-destination "$TMP_DIR" 2>/dev/null; then
        NODERED_TGZ=$(ls -1 "$TMP_DIR"/node-red-*.tgz 2>/dev/null | head -1 || true)
    fi
fi

# Backup de flows antes de actualizar
echo "  [~] Creando backup de flows..."
cp ~/.node-red/flows.json ~/.node-red/flows.json.bak 2>/dev/null && echo "  [OK] Backup: ~/.node-red/flows.json.bak" || true
cp ~/.node-red/flows_cred.json ~/.node-red/flows_cred.json.bak 2>/dev/null || true

# Parar Node-RED
echo ""
echo "  [~] Parando Node-RED..."
sudo systemctl stop nodered 2>/dev/null || true
sleep 1

# Actualizar Node-RED globalmente
echo "  [~] Descargando e instalando Node-RED $LATEST_VERSION..."
echo ""
echo "  ────────────────────────────────────────────"

# Mostrar progreso de npm
if [ -n "$NODERED_TGZ" ] && [ -f "$NODERED_TGZ" ]; then
    sudo npm install -g --no-audit --no-fund --progress=false --loglevel=error "$NODERED_TGZ" 2>&1 | while read line; do
        if echo "$line" | grep -qE '(added|removed|changed|node-red@|npm warn|npm error|packages in)'; then
            echo "  $line"
        fi
    done
else
    sudo npm install -g --no-audit --no-fund --progress=false --loglevel=error "node-red@$LATEST_VERSION" 2>&1 | while read line; do
        if echo "$line" | grep -qE '(added|removed|changed|node-red@|npm warn|npm error|packages in)'; then
            echo "  $line"
        fi
    done
fi

rm -rf "$TMP_DIR" 2>/dev/null || true

echo "  ────────────────────────────────────────────"
echo ""

# Verificar nueva versión
NEW_VERSION=$(node-red --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")

if [ "$NEW_VERSION" != "$CURRENT_VERSION" ] || [ -n "$FORCE_UPDATE" ]; then
    echo "  [OK] Node-RED actualizado: $CURRENT_VERSION → $NEW_VERSION"
else
    echo "  [OK] Node-RED reinstalado: $NEW_VERSION"
fi

# Preguntar si iniciar Node-RED
echo ""
read -p "  ¿Iniciar Node-RED ahora? [S/n]: " CONFIRMAR_START

if [ "$CONFIRMAR_START" != "n" ] && [ "$CONFIRMAR_START" != "N" ]; then
    echo ""
    echo "  [~] Iniciando Node-RED..."
    sudo systemctl start nodered
    sleep 3
    
    # Verificar que está corriendo
    if systemctl is-active --quiet nodered; then
        echo "  [OK] Node-RED iniciado correctamente"
    else
        echo "  [X] Error al iniciar Node-RED"
        echo "      Revisa los logs: journalctl -u nodered -n 50"
    fi
    
    # Reiniciar kiosko si existe
    if systemctl list-unit-files | grep -q "kiosk.service"; then
        echo "  [~] Reiniciando kiosko..."
        sudo systemctl restart kiosk.service 2>/dev/null || true
        sleep 1
        echo "  [OK] Kiosko reiniciado"
    fi
else
    echo ""
    echo "  [!] Node-RED NO iniciado"
    echo "      Para iniciarlo manualmente: sudo systemctl start nodered"
fi

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [OK] Completado"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
