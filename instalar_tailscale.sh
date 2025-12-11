#!/bin/bash
#
# Script para instalar y configurar Tailscale
# Permite SSH rápido sin pasar por el relay de RPI Connect
#

set -e

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Instalar Tailscale (SSH rápido)"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Verificar si ya está instalado
if command -v tailscale &> /dev/null; then
    TAILSCALE_VERSION=$(tailscale version 2>/dev/null | head -1 || echo "?")
    TAILSCALE_STATUS=$(tailscale status 2>&1 || echo "desconectado")
    
    echo "  [OK] Tailscale ya instalado: $TAILSCALE_VERSION"
    echo ""
    
    # Mostrar estado
    if echo "$TAILSCALE_STATUS" | grep -qi "logged out\|not logged\|stopped"; then
        echo "  [!] Estado: No conectado"
        echo ""
        read -p "  ¿Conectar a Tailscale ahora? [S/n]: " DO_LOGIN
        if [ "$DO_LOGIN" != "n" ] && [ "$DO_LOGIN" != "N" ]; then
            echo ""
            echo "  [~] Iniciando conexión..."
            echo "  → Se abrirá un enlace para autenticarte"
            echo ""
            sudo tailscale up --ssh
            echo ""
            echo "  [OK] Tailscale conectado"
        fi
    else
        echo "  [+] Estado: Conectado"
        echo ""
        # Mostrar IP de Tailscale
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "?")
        TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','?').rstrip('.'))" 2>/dev/null || echo "?")
        
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Datos de conexión SSH"
        echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  IP Tailscale:  $TAILSCALE_IP"
        echo "  Hostname:      $TAILSCALE_HOSTNAME"
        echo ""
        echo "  Comando SSH:"
        echo "    ssh $(whoami)@$TAILSCALE_IP"
        echo ""
        echo "  O usando hostname:"
        echo "    ssh $(whoami)@$TAILSCALE_HOSTNAME"
        echo ""
    fi
    
    # Opciones adicionales
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Opciones"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  1) Ver estado completo"
    echo "  2) Reconectar"
    echo "  3) Desconectar"
    echo "  4) Desinstalar Tailscale"
    echo "  0) Salir"
    echo ""
    read -p "  Opción [0-4]: " OPT
    
    case $OPT in
        1)
            echo ""
            tailscale status
            ;;
        2)
            echo ""
            echo "  [~] Reconectando..."
            sudo tailscale up --ssh
            echo "  [OK] Reconectado"
            ;;
        3)
            echo ""
            echo "  [~] Desconectando..."
            sudo tailscale down
            echo "  [OK] Desconectado"
            ;;
        4)
            echo ""
            read -p "  ¿Seguro que quieres desinstalar Tailscale? [s/N]: " CONFIRM
            if [ "$CONFIRM" = "s" ] || [ "$CONFIRM" = "S" ]; then
                echo "  [~] Desinstalando..."
                sudo tailscale down 2>/dev/null || true
                sudo apt-get remove -y tailscale
                sudo apt-get autoremove -y
                echo "  [OK] Tailscale desinstalado"
            fi
            ;;
        *)
            echo "  [OK] Saliendo"
            ;;
    esac
else
    # No está instalado, proceder con instalación
    echo "  Tailscale permite conexión SSH directa y rápida"
    echo "  sin pasar por el relay lento de RPI Connect."
    echo ""
    echo "  Ventajas:"
    echo "    - SSH instantáneo desde cualquier lugar"
    echo "    - Conexión cifrada punto a punto"
    echo "    - Gratis para uso personal (hasta 100 dispositivos)"
    echo "    - No requiere abrir puertos en el router"
    echo ""
    read -p "  ¿Instalar Tailscale? [S/n]: " DO_INSTALL
    
    if [ "$DO_INSTALL" = "n" ] || [ "$DO_INSTALL" = "N" ]; then
        echo "  [X] Instalación cancelada"
        exit 0
    fi
    
    echo ""
    echo "  [~] Instalando Tailscale..."
    echo ""
    
    # Instalar Tailscale usando el script oficial
    curl -fsSL https://tailscale.com/install.sh | sh
    
    if [ $? -ne 0 ]; then
        echo "  [X] Error en la instalación"
        exit 1
    fi
    
    echo ""
    echo "  [OK] Tailscale instalado"
    echo ""
    
    # Iniciar y conectar
    echo "  [~] Iniciando Tailscale..."
    echo "  → Se abrirá un enlace para autenticarte"
    echo "  → Copia el enlace y ábrelo en tu navegador"
    echo ""
    
    sudo tailscale up --ssh
    
    echo ""
    echo "  [OK] Tailscale configurado"
    echo ""
    
    # Mostrar datos de conexión
    sleep 2
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "?")
    
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ¡Listo! Datos de conexión SSH"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  IP Tailscale: $TAILSCALE_IP"
    echo ""
    echo "  Comando SSH desde tu PC (con Tailscale instalado):"
    echo "    ssh $(whoami)@$TAILSCALE_IP"
    echo ""
    echo "  [i] Recuerda instalar Tailscale también en tu PC:"
    echo "      https://tailscale.com/download"
    echo ""
fi

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [OK] Completado"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
