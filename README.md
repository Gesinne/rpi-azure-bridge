# MQTT to Azure IoT Hub Bridge - Docker

## Uso rápido

### 1. Configurar

Editar `docker-compose.yml` y cambiar:
```yaml
- AZURE_CONNECTION_STRING=HostName=xxx.azure-devices.net;DeviceId=xxx;SharedAccessKey=xxx
```

Por la connection string del cliente.

### 2. Desplegar

```bash
docker-compose up -d
```

### 3. Ver logs

```bash
docker-compose logs -f
```

### 4. Reiniciar

```bash
docker-compose restart
```

### 5. Parar

```bash
docker-compose down
```

---

## Variables de entorno

| Variable | Descripción | Default |
|----------|-------------|---------|
| `MQTT_BROKER` | Broker MQTT local | host.docker.internal |
| `MQTT_PORT` | Puerto MQTT | 1883 |
| `MQTT_TOPIC` | Topics a escuchar | # (todos) |
| `AZURE_CONNECTION_STRING` | Connection string del dispositivo | (requerido) |
| `SEND_INTERVAL` | Segundos entre envíos (1=S1, 10=F1) | 1 |

---

## Requisitos

- Docker y Docker Compose instalados
- Mosquitto corriendo en la Raspberry
- Node-RED enviando a localhost:1883
