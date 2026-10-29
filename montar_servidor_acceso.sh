#!/bin/bash
#
# Prepara el servidor de acceso remoto: el punto de encuentro al que llaman las
# Raspberry cuando alguien quiere entrar en ellas.
#
# Escucha en el 443 porque es el único puerto que sale en todas las instalaciones:
# muchas redes industriales filtran el 22, y es el mismo motivo por el que Tailscale y
# Raspberry Pi Connect acaban saliendo por ahí.
#
# Este servidor NO guarda nada. Solo sostiene túneles. Si se pierde, se levanta otro y
# se cambia el DNS; por eso las Raspberry apuntan a un nombre y no a una IP.
#
#   sudo ./montar_servidor_acceso.sh
#
set -euo pipefail

USUARIO=tunel
CASA=/var/lib/tunel
PUERTO_TUNEL=443

[ "$(id -u)" = "0" ] || { echo "Ejecútalo con sudo."; exit 1; }

echo "[1/4] Usuario sin shell para los túneles"
id "$USUARIO" >/dev/null 2>&1 || useradd -r -m -d "$CASA" -s /usr/sbin/nologin "$USUARIO"
install -d -m 700 -o "$USUARIO" -g "$USUARIO" "$CASA/.ssh"
touch "$CASA/.ssh/authorized_keys"
chown "$USUARIO:$USUARIO" "$CASA/.ssh/authorized_keys"
chmod 600 "$CASA/.ssh/authorized_keys"

echo "[2/4] SSH escuchando también en el $PUERTO_TUNEL"
cat > /etc/ssh/sshd_config.d/10-tuneles.conf <<CONF
# Las Raspberry llaman por el 443: en muchas instalaciones es lo único que sale.
Port 22
Port $PUERTO_TUNEL

# Nadie entra con contraseña a este servidor.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password

# El usuario de los túneles no puede hacer nada más que reenviar puertos. Lo que de
# verdad lo limita son el 'restrict' y los 'permitlisten' de cada línea de
# authorized_keys, que le dicen qué dos puertos puede abrir y ninguno más.
Match User $USUARIO
    AllowTcpForwarding remote
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
    PermitOpen none
    # Los puertos reenviados escuchan solo en el localhost del servidor: a ellos se
    # conecta el panel, nunca internet.
    GatewayPorts no
    ClientAliveInterval 60
    ClientAliveCountMax 3
CONF
sshd -t && systemctl reload ssh

echo "[3/4] Cortafuegos: solo 22 y $PUERTO_TUNEL"
if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp >/dev/null
    ufw allow "$PUERTO_TUNEL"/tcp >/dev/null
    ufw --force enable >/dev/null
    ufw status numbered | head -8
else
    echo "  (sin ufw: revisa el cortafuegos a mano)"
fi

echo "[4/4] Comprobación"
ss -tln | grep -E ":(22|$PUERTO_TUNEL) " || true
echo ""
echo "Listo. Para dar de alta un equipo:  ./alta_equipo_acceso.sh <nº> <clave pública>"
