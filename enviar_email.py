#!/usr/bin/env python3
"""
Enviar email con la configuración de registros Modbus
"""
import os
import sys
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from datetime import datetime

# Configuración SMTP desde variables de entorno
SMTP_SERVER = os.getenv('SMTP_SERVER', '')
SMTP_PORT = int(os.getenv('SMTP_PORT', '587'))
SMTP_USER = os.getenv('SMTP_USER', '')
SMTP_PASSWORD = os.getenv('SMTP_PASSWORD', '')
SMTP_FROM = os.getenv('SMTP_FROM', 'alertas@gesinne.com')
SMTP_TO = os.getenv('SMTP_TO', 'patricia.garcia@gesinne.com')
NUMERO_SERIE = os.getenv('NUMERO_SERIE', 'unknown')


def enviar_email(contenido, asunto=None):
    """Envía un email con el contenido especificado"""
    
    if not SMTP_SERVER:
        print("Error: SMTP_SERVER no configurado")
        return False
    
    if asunto is None:
        asunto = f"📋 Configuración Modbus - Equipo {NUMERO_SERIE} - {datetime.now().strftime('%Y-%m-%d %H:%M')}"
    
    # Crear mensaje
    msg = MIMEMultipart('alternative')
    msg['Subject'] = asunto
    msg['From'] = SMTP_FROM
    msg['To'] = SMTP_TO
    
    # Versión texto plano
    text_part = MIMEText(contenido, 'plain', 'utf-8')
    msg.attach(text_part)
    
    # Versión HTML (con formato monospace para la tabla)
    html_content = f"""
    <html>
    <head>
        <style>
            body {{ font-family: Arial, sans-serif; }}
            pre {{ 
                background-color: #f4f4f4; 
                padding: 15px; 
                border-radius: 5px;
                font-family: 'Courier New', monospace;
                font-size: 12px;
                overflow-x: auto;
            }}
            h2 {{ color: #2c3e50; }}
            .header {{ 
                background-color: #3498db; 
                color: white; 
                padding: 10px 20px;
                border-radius: 5px;
            }}
        </style>
    </head>
    <body>
        <div class="header">
            <h2>📋 Configuración Modbus - Equipo {NUMERO_SERIE}</h2>
            <p>Fecha: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
        </div>
        <pre>{contenido}</pre>
    </body>
    </html>
    """
    html_part = MIMEText(html_content, 'html', 'utf-8')
    msg.attach(html_part)
    
    try:
        # Conectar y enviar
        if SMTP_PORT == 465:
            server = smtplib.SMTP_SSL(SMTP_SERVER, SMTP_PORT)
        else:
            server = smtplib.SMTP(SMTP_SERVER, SMTP_PORT)
            server.starttls()
        
        if SMTP_USER and SMTP_PASSWORD:
            server.login(SMTP_USER, SMTP_PASSWORD)
        
        server.sendmail(SMTP_FROM, SMTP_TO.split(','), msg.as_string())
        server.quit()
        
        print(f"✅ Email enviado a: {SMTP_TO}")
        return True
        
    except Exception as e:
        print(f"❌ Error enviando email: {e}")
        return False


def leer_y_enviar(tarjetas="1 2 3"):
    """Lee los registros y envía por email"""
    from leer_registros import leer_todas_tarjetas
    
    contenido = leer_todas_tarjetas(tarjetas)
    print(contenido)
    print()
    
    return enviar_email(contenido)


if __name__ == "__main__":
    tarjetas = sys.argv[1] if len(sys.argv) > 1 else "1 2 3"
    leer_y_enviar(tarjetas)
