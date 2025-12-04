FROM python:3.11-slim

WORKDIR /app

# Instalar dependencias del sistema
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Instalar dependencias Python
RUN pip install --no-cache-dir \
    azure-iot-device \
    paho-mqtt \
    pymodbus \
    pyserial

# Copiar scripts
COPY mqtt_to_azure.py .
COPY leer_registros.py .
COPY enviar_email.py .

# Variables de entorno mínimas (solo para mqtt_to_azure.py)
ENV MQTT_BROKER=localhost
ENV MQTT_PORT=1883
ENV MQTT_TOPIC=#
ENV AZURE_CONNECTION_STRING=""
ENV SEND_INTERVAL=1
ENV HEALTHCHECK_PORT=8080

# Exponer puerto healthcheck
EXPOSE 8080

CMD ["python", "-u", "mqtt_to_azure.py"]
