# Acceso remoto bajo demanda (nuestro propio Raspberry Pi Connect)

Entrar a cualquier equipo —terminal y pantalla— **sin Tailscale, sin Raspberry Pi
Connect y sin gastar datos mientras nadie entra**, y funcionando igual por cable que
por SIM.

## La idea

Tailscale y RPi Connect mantienen una conexión abierta contra servidores de terceros
las veinticuatro horas: por eso puedes entrar en cualquier momento, y por eso consumen
todo el día aunque no entres.

Aquí no hace falta, porque **ya tenemos una conexión permanente con cada Raspberry**:
la del MQTT por la que manda la telemetría. Sobre ella:

1. La Raspberry escucha su tema de órdenes. Suscribirse no genera tráfico mientras
   nadie publique: **en reposo, cero bytes**.
2. Al pulsar *Conectar* en el panel, se publica la orden.
3. La Raspberry abre un **túnel inverso** hacia el servidor: la llamada sale de ella,
   así que atraviesa el NAT del cliente y el CGNAT del operador sin abrir nada.
4. En el servidor aparecen dos puertos para ese equipo: terminal y pantalla.
5. Se cierra al salir, y en cualquier caso **solo** a los 30 minutos (tope duro: 4 h).

Puertos, para que nunca se pisen: `22000 + nº de equipo` para la terminal y
`25000 + nº` para la pantalla. El 00017 son el 22017 y el 25017.

## Qué consume

| | en reposo | mientras lo usas |
|---|---|---|
| Terminal | nada | unos KB: es texto |
| Pantalla | nada | decenas de MB por sesión: va imagen |

Con pago por uso, una sesión larga de pantalla cuesta unos céntimos. Por eso el panel
abre terminal por defecto y la pantalla avisa antes.

## Montaje en el servidor

Un usuario dedicado que **solo** pueda hacer de pasarela:

```bash
sudo useradd -r -m -d /var/lib/tunel -s /usr/sbin/nologin tunel
sudo mkdir -p /var/lib/tunel/.ssh && sudo chmod 700 /var/lib/tunel/.ssh
```

En `/var/lib/tunel/.ssh/authorized_keys`, **una línea por equipo**, y cada una
autorizada a abrir únicamente sus dos puertos:

```
restrict,port-forwarding,permitlisten="22017",permitlisten="25017" ssh-ed25519 AAAA...  equipo-00017
```

`restrict` quita todo lo demás (shell, agente, X11, ejecución de órdenes) y
`permitlisten` es lo que impide que una Raspberry comprometida secuestre el puerto de
otra o abra lo que le dé la gana. **Sin esa parte, esto no se despliega.**

Y en `/etc/ssh/sshd_config`, dejar `GatewayPorts no` (es el valor por defecto): así los
puertos abiertos escuchan **solo en el localhost del servidor**, no en internet. Quien
se conecta a ellos es el panel, que corre ahí mismo.

## Montaje en la Raspberry

1. `acceso_remoto.sh` en `/home/gesinne/` (va en este repositorio).
2. Su clave privada en `/home/gesinne/.ssh/id_tunel`, una **por equipo** (si se
   comparte una sola, se pierde el aislamiento que da `permitlisten`).
3. En el flow de Node-RED, un `mqtt in` suscrito al tema de órdenes del equipo y un
   `exec` que llame al script con `abrir` o `cerrar`.

Los puertos los asigna el servidor y viajan en la orden; el script los acepta como
argumentos. No se calculan en la Raspberry: con equipos como el 73001, cualquier
fórmula del tipo `22000 + número` se sale del rango de puertos válidos.

El script arranca el `sshd` si estaba parado —en muchas Raspberry lo está a
propósito— y lo vuelve a parar al cerrar, dejándolo como estaba.

## Lo que hay que cuidar

- **La orden de abrir es la llave del equipo.** Quien pueda publicar en ese tema puede
  entrar. Tiene que ir firmada, atada a un rol y registrada: quién, a qué equipo y
  cuándo.
- **Dejar RPi Connect en cuatro o cinco equipos** como vía de rescate. Si un día falla
  el MQTT, esto no abre nada y hay que poder entrar igualmente.
- El cierre automático no es un adorno: sin él, un túnel olvidado sí gasta datos y deja
  la puerta abierta.
