#!/usr/bin/env python3
"""
Puente MQTT Local → Azure IoT Hub
Versión para Docker
"""
import os
import json
import time
import socket
import ssl
import paho.mqtt.client as mqtt
from azure.iot.device import IoTHubDeviceClient, Message

# Configuración desde variables de entorno
MQTT_BROKER = os.getenv("MQTT_BROKER", "host.docker.internal")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_TOPIC = os.getenv("MQTT_TOPIC", "#")

AZURE_CONNECTION_STRING = os.getenv("AZURE_CONNECTION_STRING", "")
SEND_INTERVAL = int(os.getenv("SEND_INTERVAL", "1"))  # 1 para S1, 10 para F1

azure_client = None
buffer = {}
last_send = 0

def check_port(host, port, timeout=5):
    """Verifica si un puerto está accesible"""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        if port == 443 or port == 8883:
            # Conexión SSL
            context = ssl.create_default_context()
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            sock = context.wrap_socket(sock, server_hostname=host)
        result = sock.connect_ex((host, port))
        sock.close()
        return result == 0
    except Exception as e:
        return False

def check_azure_connectivity():
    """Verifica conectividad a Azure IoT Hub"""
    if not AZURE_CONNECTION_STRING:
        print("❌ ERROR: AZURE_CONNECTION_STRING no configurada")
        return False
    
    # Extraer hostname de la connection string
    try:
        parts = dict(x.split('=', 1) for x in AZURE_CONNECTION_STRING.split(';'))
        hostname = parts.get('HostName', '')
    except:
        print("❌ ERROR: Connection string inválida")
        return False
    
    print(f"🔍 Verificando conectividad a {hostname}...")
    
    # Verificar puerto 8883 (MQTT)
    if check_port(hostname, 8883):
        print(f"✅ Puerto 8883 (MQTT) - OK")
    else:
        print(f"❌ Puerto 8883 (MQTT) - BLOQUEADO")
        return False
    
    # Verificar puerto 443 (HTTPS)
    if check_port(hostname, 443):
        print(f"✅ Puerto 443 (HTTPS) - OK")
    else:
        print(f"⚠️ Puerto 443 (HTTPS) - BLOQUEADO (opcional)")
    
    return True

def connect_azure():
    global azure_client
    if not AZURE_CONNECTION_STRING:
        print("❌ ERROR: AZURE_CONNECTION_STRING no configurada")
        return False
    try:
        if azure_client:
            try:
                azure_client.disconnect()
            except:
                pass
        azure_client = IoTHubDeviceClient.create_from_connection_string(
            AZURE_CONNECTION_STRING,
            keep_alive=60
        )
        azure_client.connect()
        print("✅ Conectado a Azure IoT Hub")
        return True
    except Exception as e:
        print(f"❌ Error: {e}")
        return False

def send_buffer():
    global buffer, last_send
    
    if not buffer:
        return
    
    try:
        if SEND_INTERVAL > 1:
            # Agrupar fases en un JSON
            payload = json.dumps(buffer)
        else:
            # Enviar cada fase por separado
            for topic, csv_data in buffer.items():
                payload_with_topic = f"{topic}|{csv_data}"
                azure_msg = Message(payload_with_topic)
                azure_client.send_message(azure_msg)
                print(f"📤 [{topic}] Enviado")
            buffer = {}
            last_send = time.time()
            return
        
        azure_msg = Message(payload)
        azure_msg.content_type = "application/json"
        azure_client.send_message(azure_msg)
        
        fases = list(buffer.keys())
        print(f"📤 Enviado a Azure: {fases}")
        buffer = {}
        last_send = time.time()
        
    except Exception as e:
        print(f"⚠️ Reconectando: {e}")
        connect_azure()

def on_connect(client, userdata, flags, rc):
    print(f"✅ Conectado a MQTT {MQTT_BROKER}:{MQTT_PORT}")
    client.subscribe(MQTT_TOPIC)

def on_message(client, userdata, msg):
    global buffer, last_send
    
    topic = msg.topic
    payload = msg.payload.decode('utf-8')
    
    buffer[topic] = payload
    
    now = time.time()
    if (now - last_send) >= SEND_INTERVAL and buffer:
        send_buffer()

def main():
    global last_send
    last_send = time.time()
    
    print("=" * 50)
    print("MQTT → Azure IoT Hub Bridge")
    print(f"MQTT: {MQTT_BROKER}:{MQTT_PORT}")
    print(f"Intervalo: {SEND_INTERVAL}s")
    print("=" * 50)
    
    # Verificar conectividad antes de iniciar
    if not check_azure_connectivity():
        print("❌ No hay conectividad a Azure. Verifica los puertos de red.")
        print("   Reintentando en 30 segundos...")
        time.sleep(30)
        return main()  # Reintentar
    
    connect_azure()
    
    mqtt_client = mqtt.Client()
    mqtt_client.on_connect = on_connect
    mqtt_client.on_message = on_message
    
    while True:
        try:
            mqtt_client.connect(MQTT_BROKER, MQTT_PORT, 60)
            mqtt_client.loop_forever()
        except Exception as e:
            print(f"⚠️ Error MQTT: {e}, reintentando en 5s...")
            time.sleep(5)

if __name__ == "__main__":
    main()
