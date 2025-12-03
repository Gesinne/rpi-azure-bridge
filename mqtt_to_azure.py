#!/usr/bin/env python3
"""
Puente MQTT Local → Azure IoT Hub
Versión para Docker con:
- Buffer local persistente si pierde conexión
- Reconexión con backoff exponencial
- Healthcheck HTTP
"""
import os
import json
import time
import socket
import ssl
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
import paho.mqtt.client as mqtt
from azure.iot.device import IoTHubDeviceClient, Message

# Configuración desde variables de entorno
MQTT_BROKER = os.getenv("MQTT_BROKER", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_TOPIC = os.getenv("MQTT_TOPIC", "#")

AZURE_CONNECTION_STRING = os.getenv("AZURE_CONNECTION_STRING", "")
SEND_INTERVAL = int(os.getenv("SEND_INTERVAL", "1"))  # 1 para S1, 10 para F1
HEALTHCHECK_PORT = int(os.getenv("HEALTHCHECK_PORT", "8080"))
BUFFER_FILE = "/tmp/azure_buffer.json"
MAX_BUFFER_SIZE = 1000  # Máximo mensajes en buffer offline

azure_client = None
buffer = {}
offline_buffer = []  # Buffer para cuando Azure no está disponible
last_send = 0
azure_connected = False
mqtt_connected = False
messages_sent = 0
messages_buffered = 0

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

def load_offline_buffer():
    """Carga el buffer offline desde disco"""
    global offline_buffer
    try:
        if os.path.exists(BUFFER_FILE):
            with open(BUFFER_FILE, 'r') as f:
                offline_buffer = json.load(f)
            print(f"📂 Cargados {len(offline_buffer)} mensajes del buffer offline")
    except Exception as e:
        print(f"⚠️ Error cargando buffer: {e}")
        offline_buffer = []

def save_offline_buffer():
    """Guarda el buffer offline a disco"""
    try:
        with open(BUFFER_FILE, 'w') as f:
            json.dump(offline_buffer, f)
    except Exception as e:
        print(f"⚠️ Error guardando buffer: {e}")

def add_to_offline_buffer(data):
    """Añade mensaje al buffer offline"""
    global offline_buffer, messages_buffered
    if len(offline_buffer) < MAX_BUFFER_SIZE:
        offline_buffer.append({"timestamp": time.time(), "data": data})
        messages_buffered += 1
        save_offline_buffer()
    else:
        # Eliminar el más antiguo
        offline_buffer.pop(0)
        offline_buffer.append({"timestamp": time.time(), "data": data})

def flush_offline_buffer():
    """Envía mensajes del buffer offline a Azure"""
    global offline_buffer, messages_sent
    if not offline_buffer or not azure_connected:
        return
    
    print(f"📤 Enviando {len(offline_buffer)} mensajes del buffer offline...")
    sent = 0
    failed = []
    
    for item in offline_buffer:
        try:
            payload = json.dumps(item["data"]) if isinstance(item["data"], dict) else item["data"]
            azure_msg = Message(payload)
            azure_client.send_message(azure_msg)
            sent += 1
            messages_sent += 1
        except Exception as e:
            failed.append(item)
    
    offline_buffer = failed
    save_offline_buffer()
    
    if sent > 0:
        print(f"✅ Enviados {sent} mensajes del buffer offline")
    if failed:
        print(f"⚠️ {len(failed)} mensajes pendientes")

def connect_azure(retry_count=0):
    global azure_client, azure_connected
    if not AZURE_CONNECTION_STRING:
        print("❌ ERROR: AZURE_CONNECTION_STRING no configurada")
        return False
    
    # Backoff exponencial: 5s, 10s, 20s, 40s, max 60s
    backoff = min(5 * (2 ** retry_count), 60)
    
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
        azure_connected = True
        print("✅ Conectado a Azure IoT Hub")
        
        # Enviar mensajes pendientes del buffer offline
        flush_offline_buffer()
        return True
    except Exception as e:
        azure_connected = False
        print(f"❌ Error: {e}")
        if retry_count < 5:
            print(f"⏳ Reintentando en {backoff}s... (intento {retry_count + 1}/5)")
            time.sleep(backoff)
            return connect_azure(retry_count + 1)
        return False

def send_buffer():
    global buffer, last_send, azure_connected, messages_sent
    
    if not buffer:
        return
    
    # Si no hay conexión a Azure, guardar en buffer offline
    if not azure_connected:
        add_to_offline_buffer(buffer.copy())
        print(f"💾 Guardado en buffer offline ({len(offline_buffer)} pendientes)")
        buffer = {}
        last_send = time.time()
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
                messages_sent += 1
                print(f"📤 [{topic}] Enviado")
            buffer = {}
            last_send = time.time()
            return
        
        azure_msg = Message(payload)
        azure_msg.content_type = "application/json"
        azure_client.send_message(azure_msg)
        messages_sent += 1
        
        fases = list(buffer.keys())
        print(f"📤 Enviado a Azure: {fases}")
        buffer = {}
        last_send = time.time()
        
    except Exception as e:
        azure_connected = False
        print(f"⚠️ Error enviando, guardando en buffer: {e}")
        add_to_offline_buffer(buffer.copy())
        buffer = {}
        # Reconectar en background
        threading.Thread(target=connect_azure, daemon=True).start()

def on_connect(client, userdata, flags, rc):
    global mqtt_connected
    mqtt_connected = True
    print(f"✅ Conectado a MQTT {MQTT_BROKER}:{MQTT_PORT}")
    client.subscribe(MQTT_TOPIC)

def on_disconnect(client, userdata, rc):
    global mqtt_connected
    mqtt_connected = False
    print(f"⚠️ Desconectado de MQTT: {rc}")

def on_message(client, userdata, msg):
    global buffer, last_send
    
    topic = msg.topic
    payload = msg.payload.decode('utf-8')
    
    buffer[topic] = payload
    
    now = time.time()
    if (now - last_send) >= SEND_INTERVAL and buffer:
        send_buffer()

# =============================================================================
# HEALTHCHECK HTTP SERVER
# =============================================================================

class HealthHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Silenciar logs HTTP
    
    def do_GET(self):
        if self.path == '/health' or self.path == '/':
            status = {
                "status": "healthy" if azure_connected and mqtt_connected else "degraded",
                "azure_connected": azure_connected,
                "mqtt_connected": mqtt_connected,
                "messages_sent": messages_sent,
                "messages_buffered": messages_buffered,
                "offline_buffer_size": len(offline_buffer),
                "uptime_seconds": int(time.time() - start_time)
            }
            self.send_response(200 if status["status"] == "healthy" else 503)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(status).encode())
        else:
            self.send_response(404)
            self.end_headers()

def start_healthcheck_server():
    """Inicia servidor HTTP para healthcheck"""
    try:
        server = HTTPServer(('0.0.0.0', HEALTHCHECK_PORT), HealthHandler)
        print(f"🏥 Healthcheck en http://0.0.0.0:{HEALTHCHECK_PORT}/health")
        server.serve_forever()
    except Exception as e:
        print(f"⚠️ Error iniciando healthcheck: {e}")

# =============================================================================
# MAIN
# =============================================================================

start_time = time.time()

def main():
    global last_send, start_time
    last_send = time.time()
    start_time = time.time()
    
    print("=" * 50)
    print("MQTT → Azure IoT Hub Bridge v2.0")
    print(f"MQTT: {MQTT_BROKER}:{MQTT_PORT}")
    print(f"Intervalo: {SEND_INTERVAL}s")
    print(f"Buffer máximo: {MAX_BUFFER_SIZE} mensajes")
    print("=" * 50)
    
    # Cargar buffer offline si existe
    load_offline_buffer()
    
    # Iniciar servidor healthcheck en background
    threading.Thread(target=start_healthcheck_server, daemon=True).start()
    
    # Verificar conectividad antes de iniciar
    if not check_azure_connectivity():
        print("❌ No hay conectividad a Azure. Verifica los puertos de red.")
        print("   Reintentando en 30 segundos...")
        time.sleep(30)
        return main()  # Reintentar
    
    connect_azure()
    
    mqtt_client = mqtt.Client()
    mqtt_client.on_connect = on_connect
    mqtt_client.on_disconnect = on_disconnect
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
