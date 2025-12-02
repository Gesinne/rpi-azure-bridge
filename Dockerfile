FROM python:3.11-slim

WORKDIR /app

# Instalar dependencias
RUN pip install --no-cache-dir azure-iot-device paho-mqtt

# Copiar script
COPY mqtt_to_azure.py .

# Variables de entorno por defecto
ENV MQTT_BROKER=host.docker.internal
ENV MQTT_PORT=1883
ENV MQTT_TOPIC=#
ENV AZURE_CONNECTION_STRING=""
ENV SEND_INTERVAL=1

CMD ["python", "-u", "mqtt_to_azure.py"]
