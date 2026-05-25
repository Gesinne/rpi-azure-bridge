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

# Configuración SMTP - HARDCODEADO, NO MODIFICAR
SMTP_SERVER = "smtp.gmail.com"
SMTP_PORT = 587
SMTP_USER = "gesinneasturias@gmail.com"
SMTP_PASSWORD = "pegdowikwjuqpeoq"
SMTP_FROM = "gesinneasturias@gmail.com"
SMTP_TO = "patricia.garcia@gesinne.com,victorbarrero@gesinne.com"


def enviar_email(contenido, asunto=None, numero_serie="N/A"):
    """Envía un email con el contenido especificado"""
    
    if not SMTP_SERVER:
        print("Error: SMTP_SERVER no configurado")
        return False
    
    if asunto is None:
        asunto = f"📋 Configuración Modbus - Equipo {numero_serie} - {datetime.now().strftime('%Y-%m-%d %H:%M')}"
    
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
            <h2>📋 Configuración Modbus - Equipo {numero_serie}</h2>
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


def leer_y_enviar():
    """Lee los registros de las 3 fases con reintentos y envía por email"""
    import time
    from leer_registros import leer_tarjeta, REGISTROS, SERIAL_PORT
    from modbus_helper import open_modbus_client

    # Leer las 3 fases con reintentos
    placas_leidas = {}
    max_intentos = 10
    intento = 0

    while len(placas_leidas) < 3 and intento < max_intentos:
        intento += 1
        fases_pendientes = [u for u in [1, 2, 3] if u not in placas_leidas]

        if intento > 1:
            print(f"  🔄 Reintento {intento}/{max_intentos} - Fases pendientes: {', '.join([f'L{u}' for u in fases_pendientes])}")
            time.sleep(1)

        client = open_modbus_client(port=SERIAL_PORT, timeout=1)
        
        if client.connect():
            for unit_id in fases_pendientes:
                data = leer_tarjeta(client, unit_id)
                if len(data) > 48:
                    placas_leidas[unit_id] = data
                    print(f"  ✅ L{unit_id} leída correctamente")
            client.close()
    
    # Verificar que tenemos las 3 fases
    if len(placas_leidas) < 3:
        fases_ok = [f"L{k}" for k in sorted(placas_leidas.keys())]
        fases_fail = [f"L{k}" for k in [1,2,3] if k not in placas_leidas]
        print(f"⚠️  Solo se pudieron leer {len(placas_leidas)} fases: {', '.join(fases_ok)}")
        print(f"❌ Fases sin respuesta después de {max_intentos} intentos: {', '.join(fases_fail)}")
        print("❌ No se envía email hasta tener las 3 fases")
        return False
    
    print(f"  ✅ Las 3 fases leídas correctamente")
    
    # Obtener números de serie de cada placa
    sn_l1 = placas_leidas[1][41]
    sn_l2 = placas_leidas[2][41]
    sn_l3 = placas_leidas[3][41]
    
    # Construir contenido
    contenido = []
    contenido.append("=" * 80)
    contenido.append(f"PARÁMETROS DE CONFIGURACIÓN - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    contenido.append(f"Placas: L1={sn_l1} / L2={sn_l2} / L3={sn_l3}")
    contenido.append("=" * 80)
    contenido.append("")
    contenido.append("PLACAS DETECTADAS:")
    contenido.append(f"  • L1 (Fase 1) - Nº Serie Placa: {sn_l1}")
    contenido.append(f"  • L2 (Fase 2) - Nº Serie Placa: {sn_l2}")
    contenido.append(f"  • L3 (Fase 3) - Nº Serie Placa: {sn_l3}")
    contenido.append("=" * 80)
    
    for unit_id in [1, 2, 3]:
        data = placas_leidas[unit_id]
        sn_placa = data[41]
        fase = f"L{unit_id}"
        
        contenido.append("")
        contenido.append("╔" + "═" * 78 + "╗")
        contenido.append(f"║  {fase} - Nº Serie Placa: {sn_placa:<10}  -  Dirección Modbus: {data[48]}                  ║")
        contenido.append("╚" + "═" * 78 + "╝")
        contenido.append("")
        contenido.append("Reg | Parámetro                | Valor      | Descripción")
        contenido.append("----|--------------------------|------------|--------------------------------------------------")
        
        for i in range(len(data)):
            if i in REGISTROS:
                desc, nombre = REGISTROS[i]
                contenido.append(f"{i:3d} | {nombre:24s} | {data[i]:10d} | {desc}")
    
    contenido.append("")
    contenido.append("=" * 80)
    
    texto = "\n".join(contenido)
    print(texto)
    print()
    
    asunto = f"📋 Configuración Modbus - Placas: {sn_l1}/{sn_l2}/{sn_l3} - {datetime.now().strftime('%Y-%m-%d %H:%M')}"
    return enviar_email(texto, asunto)


if __name__ == "__main__":
    leer_y_enviar()
