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

echo "  [~] Comprobando versiones..."
echo ""

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
sudo npm install -g --unsafe-perm node-red@latest 2>&1 | while read line; do
    # Filtrar solo líneas relevantes
    if echo "$line" | grep -qE '(added|removed|changed|node-red@|npm warn|npm error|packages in)'; then
        echo "  $line"
    fi
done

echo "  ────────────────────────────────────────────"
echo ""

# Verificar nueva versión
NEW_VERSION=$(node-red --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")

if [ "$NEW_VERSION" != "$CURRENT_VERSION" ] || [ "$FORCE_UPDATE" ]; then
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
    if systemctl list-unit-files kiosk.service &>/dev/null; then
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
