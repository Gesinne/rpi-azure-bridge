#!/bin/bash
# ============================================================================
# INSTALADOR DE CONTENEDOR GESINNE - SOLO EJECUTAR UNA VEZ
# Una vez instalado, este contenedor NO se puede modificar ni actualizar
# ============================================================================

set -e

INSTALL_DIR="/opt/gesinne-rpi"

# Verificar si ya está instalado
if [ -d "$INSTALL_DIR" ]; then
    echo ""
    echo "  ⚠️  El contenedor ya está instalado en $INSTALL_DIR"
    echo "  ⚠️  NO se puede reinstalar ni modificar"
    echo ""
    echo "  Para ejecutar el envío de email:"
    echo "    docker exec gesinne-rpi python enviar_email.py"
    echo ""
    exit 0
fi

echo ""
echo "  ============================================"
echo "  INSTALANDO CONTENEDOR GESINNE (INMUTABLE)"
echo "  ============================================"
echo ""

# Crear directorio protegido
sudo mkdir -p "$INSTALL_DIR"

# Copiar archivos necesarios
sudo cp Dockerfile "$INSTALL_DIR/"
sudo cp docker-compose.yml "$INSTALL_DIR/"
sudo cp mqtt_to_azure.py "$INSTALL_DIR/"
sudo cp leer_registros.py "$INSTALL_DIR/"
sudo cp enviar_email.py "$INSTALL_DIR/"

# Proteger archivos (solo root puede modificar)
sudo chmod 644 "$INSTALL_DIR"/*
sudo chmod 755 "$INSTALL_DIR"
sudo chown -R root:root "$INSTALL_DIR"

# Hacer los archivos inmutables (ni siquiera root puede modificarlos sin quitar el flag)
sudo chattr +i "$INSTALL_DIR/enviar_email.py"
sudo chattr +i "$INSTALL_DIR/leer_registros.py"
sudo chattr +i "$INSTALL_DIR/Dockerfile"
sudo chattr +i "$INSTALL_DIR/docker-compose.yml"

echo "  ✅ Archivos copiados a $INSTALL_DIR"
echo "  🔒 Archivos protegidos con chattr +i (inmutables)"

# Construir y levantar contenedor
cd "$INSTALL_DIR"
sudo docker-compose up -d --build

echo ""
echo "  ============================================"
echo "  ✅ INSTALACIÓN COMPLETADA"
echo "  ============================================"
echo ""
echo "  El contenedor está corriendo y es INMUTABLE."
echo "  Los archivos en $INSTALL_DIR no se pueden modificar."
echo ""
echo "  Para enviar email con configuración:"
echo "    docker exec gesinne-rpi python enviar_email.py"
echo ""
echo "  Para ver logs:"
echo "    docker logs gesinne-rpi"
echo ""
