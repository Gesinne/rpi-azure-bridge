#!/bin/bash
# Script para enviar registros por email
# Wrapper para enviar_email.py

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ejecutar el script Python
python3 "$SCRIPT_DIR/enviar_email.py"
