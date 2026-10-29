#!/bin/bash
#
# Terminal y pantalla de los equipos dentro del navegador, como hace Raspberry Pi
# Connect pero en casa.
#
# Se lanza EN EL SERVIDOR DE ACCESO (acceso.gesinne.cloud), una sola vez:
#
#   sudo ./montar_terminal_web.sh
#
# Lo que deja montado:
#   - ttyd (terminal) y noVNC + websockify (pantalla), que no hablan con internet:
#     escuchan sólo en el localhost y los levanta el portero cuando hace falta.
#   - el portero, que es quien decide qué sesión se abre y por cuánto tiempo.
#   - nginx en el 8443 con certificado de verdad. El 443 no se puede usar: ahí está el
#     SSH por el que llaman las Raspberry.
#   - una clave propia de este servidor para entrar en los equipos. Es la que evita
#     tener llaves repartidas por los portátiles: quien entra en la Raspberry es este
#     servidor, y a las personas se les da o se les quita el acceso en el panel.
#
set -euo pipefail

NOMBRE=${NOMBRE:-acceso.gesinne.cloud}
PUERTO_WEB=8443
CLAVE_RPI=/etc/gesinne/acceso_rpi.key
TOKEN=/etc/gesinne/portero.token
ORIGEN=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" = "0" ] || { echo "Ejecútalo con sudo."; exit 1; }
paso() { printf '\n\033[1m%s\033[0m\n' "$*"; }

paso "1/7 · Programas"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ttyd novnc websockify nginx certbot python3-certbot-nginx

paso "2/7 · Certificado para $NOMBRE"
# Let's Encrypt en vez de copiar aquí el comodín de la empresa: una clave privada que
# viaja es una clave privada perdida. Necesita el 80 abierto un momento.
if [ ! -s "/etc/letsencrypt/live/$NOMBRE/fullchain.pem" ]; then
  systemctl stop nginx 2>/dev/null || true
  ufw allow 80/tcp >/dev/null 2>&1 || true
  certbot certonly --standalone --non-interactive --agree-tos \
    --register-unsafely-without-email -d "$NOMBRE" \
    || { echo "No he podido sacar el certificado. ¿Está el 80 abierto y el DNS en gris?"; exit 1; }
else
  echo "    ya había certificado"
fi

paso "3/7 · Clave de este servidor para entrar en los equipos"
install -d -m 755 /etc/gesinne
if [ ! -f "$CLAVE_RPI" ]; then
  ssh-keygen -t ed25519 -N '' -C "servidor-acceso" -f "$CLAVE_RPI" >/dev/null
  chmod 600 "$CLAVE_RPI"
fi
echo "    Esta es la clave que hay que autorizar en cada Raspberry (usuario gesinne):"
echo
cat "$CLAVE_RPI.pub"
echo

paso "4/7 · Token del portero"
if [ ! -s "$TOKEN" ]; then
  openssl rand -hex 32 > "$TOKEN"
  chmod 600 "$TOKEN"
fi
echo "    guardado en $TOKEN (hay que ponerlo también en la admin-api)"

paso "5/7 · El portero"
install -m 755 "$ORIGEN/portero_acceso.py" /usr/local/bin/portero_acceso.py
install -d -m 750 /var/lib/portero
cat > /etc/systemd/system/gesinne-portero.service <<UNIT
[Unit]
Description=Portero del acceso remoto de Gesinne
After=network-online.target

[Service]
Type=simple
Environment=PORTERO_PUBLICA=https://$NOMBRE:$PUERTO_WEB
Environment=PORTERO_CLAVE_RPI=$CLAVE_RPI
ExecStart=/bin/sh -c 'PORTERO_TOKEN=\$(cat $TOKEN) /usr/bin/python3 /usr/local/bin/portero_acceso.py'
Restart=always
RestartSec=5
# No necesita ser root para nada de lo que hace, pero sí leer la clave de los equipos.
User=root
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable gesinne-portero
# restart y no --now: si ya estaba en marcha, --now no lo reinicia y seguiría con el
# código anterior, que es justo lo que se acaba de cambiar.
systemctl restart gesinne-portero

paso "6/7 · nginx en el $PUERTO_WEB"
cat > /etc/nginx/sites-available/acceso <<CONF
# Las sesiones viven en puertos del localhost que el portero reparte. Aquí no se sabe
# de antemano cuál es cada una: por eso se le pregunta al portero por cada petición,
# y es él quien dice si la dirección vale y a qué puerto va.
server {
    listen $PUERTO_WEB ssl;
    http2 on;
    server_name $NOMBRE;

    ssl_certificate     /etc/letsencrypt/live/$NOMBRE/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$NOMBRE/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    # Esto no es una web para visitar: no debe salir en ningún buscador ni quedarse
    # guardado en el navegador de nadie.
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header X-Frame-Options "SAMEORIGIN" always;

    # Lo que pide el panel (crear o cerrar sesiones). Va con su token.
    location /api/ {
        proxy_pass http://127.0.0.1:8900/;
        proxy_set_header Host \$host;
    }

    # Dos caminos distintos porque los dos programas esperan cosas distintas:
    #
    #   /t/<id>/  terminal. A ttyd se le dice con --base-path bajo qué dirección lo
    #             sirven, así que hay que pasarle la dirección ENTERA, con prefijo.
    #   /p/<id>/  pantalla. websockify sirve en la raíz y no entiende de prefijos, así
    #             que hay que quitárselo antes de pasárselo.
    #
    # Las expresiones van entrecomilladas a propósito: sin comillas, nginx ve la llave
    # de {32} como el principio de un bloque y se corta ahí.

    location ~ "^/(t|p)/([a-f0-9]{32})\$" {
        return 301 \$scheme://\$host:$PUERTO_WEB\$uri/;
    }

    location ~ "^/t/(?<sid>[a-f0-9]{32})/" {
        auth_request /_valida;
        auth_request_set \$destino \$upstream_http_x_backend;

        proxy_pass http://\$destino;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 12h;
        proxy_buffering off;
    }

    location ~ "^/p/(?<sid>[a-f0-9]{32})(?<resto>/.*)\$" {
        auth_request /_valida;
        auth_request_set \$destino \$upstream_http_x_backend;

        proxy_pass http://\$destino\$resto;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 12h;
        proxy_buffering off;
    }

    location = /_valida {
        internal;
        proxy_pass http://127.0.0.1:8900/validar;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Sid \$sid;
    }

    location / { return 404; }
}
CONF
ln -sf /etc/nginx/sites-available/acceso /etc/nginx/sites-enabled/acceso
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl restart nginx
ufw allow $PUERTO_WEB/tcp >/dev/null 2>&1 || true

paso "7/7 · Comprobación"
sleep 1
systemctl is-active --quiet gesinne-portero && echo "    portero: en marcha" || echo "    portero: PARADO"
systemctl is-active --quiet nginx && echo "    nginx:   en marcha" || echo "    nginx:   PARADO"
echo -n "    el 8443 contesta: "
curl -sk -o /dev/null -w '%{http_code}\n' "https://$NOMBRE:$PUERTO_WEB/" || echo "no"

paso "Queda por hacer, fuera de este servidor"
cat <<FIN
  1. Autorizar la clave de arriba en cada Raspberry, en el usuario gesinne. Para el
     equipo que ya tiene túnel:
       ssh -p <puerto> gesinne@localhost "echo '<clave .pub>' >> ~/.ssh/authorized_keys"
     Para los nuevos, va dentro de instalar_timbre.sh.

  2. Darle a la admin-api el token del portero ($TOKEN) como secreto de Swarm
     'portero_token', y la dirección https://$NOMBRE:$PUERTO_WEB.
FIN
