FROM python:3.11-slim

WORKDIR /app

# Instalar curl para healthcheck y dependencias Python
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir azure-iot-device paho-mqtt

# Copiar script
COPY mqtt_to_azure.py .

# Variables de entorno por defecto
ENV MQTT_BROKER=localhost
ENV MQTT_PORT=1883
ENV MQTT_TOPIC=#
ENV AZURE_CONNECTION_STRING=""
ENV SEND_INTERVAL=1
ENV HEALTHCHECK_PORT=8080

# Exponer puerto healthcheck
EXPOSE 8080

CMD ["python", "-u", "mqtt_to_azure.py"]
