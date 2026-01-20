#!/bin/bash
# Script para alertar de reinicios fuera de horario programado
# Se ejecuta al inicio del sistema via cron @reboot

# Esperar a que la red esté disponible (máximo 60 segundos)
MAX_WAIT=60
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        break
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo "[$(date)] [X] No hay conexión a internet después de ${MAX_WAIT}s"
    exit 1
fi

# Configuración
HORA_PROGRAMADA="23:30"
VENTANA_MINUTOS=5  # Tolerancia de +/- 5 minutos

# Email
SMTP_TO="patricia.garcia@gesinne.com,victorbarrero@gesinne.com,joseluis.nicolas@gesinne.com"

# Obtener número de serie del equipo desde equipo_config.json
if [ -f /home/gesinne/config/equipo_config.json ]; then
    SERIAL=$(python3 -c "import json; print(json.load(open('/home/gesinne/config/equipo_config.json')).get('serie', 'DESCONOCIDO'))" 2>/dev/null || echo "DESCONOCIDO")
elif [ -f /home/pi/config/equipo_config.json ]; then
    SERIAL=$(python3 -c "import json; print(json.load(open('/home/pi/config/equipo_config.json')).get('serie', 'DESCONOCIDO'))" 2>/dev/null || echo "DESCONOCIDO")
else
    SERIAL="DESCONOCIDO"
fi

# Obtener hora actual
HORA_ACTUAL=$(date +%H:%M)
HORA_ACTUAL_MIN=$(date +%H)*60+$(date +%M)
HORA_ACTUAL_MIN=$((10#$(date +%H)*60 + 10#$(date +%M)))

# Calcular hora programada en minutos
HORA_PROG_H=$(echo $HORA_PROGRAMADA | cut -d: -f1)
HORA_PROG_M=$(echo $HORA_PROGRAMADA | cut -d: -f2)
HORA_PROG_MIN=$((10#$HORA_PROG_H*60 + 10#$HORA_PROG_M))

# Calcular diferencia
DIFF=$((HORA_ACTUAL_MIN - HORA_PROG_MIN))
if [ $DIFF -lt 0 ]; then
    DIFF=$((-DIFF))
fi

# Si está dentro de la ventana permitida, no alertar
if [ $DIFF -le $VENTANA_MINUTOS ]; then
    echo "[$(date)] Reinicio programado detectado a las $HORA_ACTUAL (dentro de ventana $HORA_PROGRAMADA ± ${VENTANA_MINUTOS}min)"
    exit 0
fi

# Reinicio fuera de horario - enviar alerta
echo "[$(date)] ⚠️ REINICIO NO PROGRAMADO detectado a las $HORA_ACTUAL"

# Obtener información del sistema
UPTIME=$(uptime -p 2>/dev/null || echo "desconocido")
LAST_BOOT=$(who -b 2>/dev/null | awk '{print $3, $4}' || date)
IP_LOCAL=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "desconocida")
KERNEL=$(uname -r)
TEMP=$(vcgencmd measure_temp 2>/dev/null | cut -d= -f2 || echo "N/A")

# Detectar tipo de conexión
CONEXION="Desconocida"
if ip link show eth0 2>/dev/null | grep -q "state UP"; then
    CONEXION="Cable Ethernet (eth0)"
elif ip link show wlan0 2>/dev/null | grep -q "state UP"; then
    SSID=$(iwgetid -r 2>/dev/null || echo "")
    if [ -n "$SSID" ]; then
        CONEXION="WiFi ($SSID)"
    else
        CONEXION="WiFi"
    fi
elif ip link show usb0 2>/dev/null | grep -q "state UP"; then
    CONEXION="USB/Router 4G (usb0)"
else
    # Buscar cualquier interfaz activa
    IFACE=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
    if [ -n "$IFACE" ]; then
        CONEXION="$IFACE"
    fi
fi

# Intentar obtener última razón de apagado
LAST_SHUTDOWN=""
if [ -f /var/log/syslog ]; then
    LAST_SHUTDOWN=$(grep -i "shutdown\|reboot\|power" /var/log/syslog 2>/dev/null | tail -5)
fi

# Enviar email
python3 << EOFEMAIL
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from datetime import datetime

SMTP_SERVER = "smtp.gmail.com"
SMTP_PORT = 587
SMTP_USER = "gesinneasturias@gmail.com"
SMTP_PASSWORD = "pegdowikwjuqpeoq"
SMTP_FROM = "gesinneasturias@gmail.com"
SMTP_TO = "$SMTP_TO"

SERIAL = "$SERIAL"
HORA_ACTUAL = "$HORA_ACTUAL"
HORA_PROGRAMADA = "$HORA_PROGRAMADA"
IP_LOCAL = "$IP_LOCAL"
KERNEL = "$KERNEL"
TEMP = "$TEMP"
LAST_BOOT = "$LAST_BOOT"
CONEXION = "$CONEXION"

msg = MIMEMultipart('alternative')
msg['Subject'] = f"⚠️ REINICIO NO PROGRAMADO - Equipo {SERIAL} - {HORA_ACTUAL}"
msg['From'] = SMTP_FROM
msg['To'] = SMTP_TO

html = f"""
<html>
<head>
<style>
body {{ font-family: Arial, sans-serif; }}
.header {{ background-color: #e74c3c; color: white; padding: 15px 20px; border-radius: 5px 5px 0 0; }}
.content {{ background-color: #f9f9f9; padding: 20px; border: 1px solid #ddd; border-radius: 0 0 5px 5px; }}
.info {{ margin: 10px 0; }}
.label {{ font-weight: bold; color: #333; }}
.warning {{ color: #e74c3c; font-weight: bold; }}
table {{ border-collapse: collapse; width: 100%; margin-top: 15px; }}
td, th {{ border: 1px solid #ddd; padding: 8px; text-align: left; }}
th {{ background-color: #3498db; color: white; }}
</style>
</head>
<body>
<div class="header">
<h2>⚠️ ALERTA: Reinicio No Programado</h2>
</div>
<div class="content">
<p class="warning">El equipo se ha reiniciado fuera del horario programado.</p>

<table>
<tr><th colspan="2">Información del Equipo</th></tr>
<tr><td><b>Número de Serie</b></td><td>{SERIAL}</td></tr>
<tr><td><b>Hora del Reinicio</b></td><td>{HORA_ACTUAL}</td></tr>
<tr><td><b>Hora Programada</b></td><td>{HORA_PROGRAMADA}</td></tr>
<tr><td><b>Fecha/Hora Boot</b></td><td>{LAST_BOOT}</td></tr>
<tr><td><b>IP Local</b></td><td>{IP_LOCAL}</td></tr>
<tr><td><b>Kernel</b></td><td>{KERNEL}</td></tr>
<tr><td><b>Temperatura</b></td><td>{TEMP}</td></tr>
<tr><td><b>Tipo Conexión</b></td><td>{CONEXION}</td></tr>
</table>

<p style="margin-top: 20px; color: #666; font-size: 12px;">
Este reinicio puede deberse a: corte de luz, fallo de alimentación, error del sistema, o reinicio manual no autorizado.
</p>
</div>
</body>
</html>
"""

text = f"""
⚠️ ALERTA: Reinicio No Programado

El equipo {SERIAL} se ha reiniciado a las {HORA_ACTUAL}.
Hora programada: {HORA_PROGRAMADA}

IP: {IP_LOCAL}
Kernel: {KERNEL}
Temperatura: {TEMP}
Conexión: {CONEXION}
"""

msg.attach(MIMEText(text, 'plain', 'utf-8'))
msg.attach(MIMEText(html, 'html', 'utf-8'))

try:
    server = smtplib.SMTP(SMTP_SERVER, SMTP_PORT)
    server.starttls()
    server.login(SMTP_USER, SMTP_PASSWORD)
    server.sendmail(SMTP_FROM, SMTP_TO.split(','), msg.as_string())
    server.quit()
    print(f"[OK] Email enviado a: {SMTP_TO}")
except Exception as e:
    print(f"[X] Error enviando email: {e}")
EOFEMAIL

echo "[$(date)] Alerta de reinicio procesada"
