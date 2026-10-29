#!/usr/bin/env python3
"""
El timbre: recibe por MQTT la orden de abrir o cerrar el acceso a este equipo.

La conexión MQTT ya existe para la telemetría, así que escuchar no cuesta ni un byte.
Pero el broker acepta a cualquiera sin contraseña y está abierto a internet, así que
una orden a pelo sería una llave tirada en la calle: cualquiera podría poner al parque
entero a abrir túneles.

Por eso la orden va firmada. Cada equipo tiene su propio secreto, distinto del de los
demás, y aquí se comprueban tres cosas antes de mover un dedo:

  - que la firma cuadra con el secreto de ESTE equipo,
  - que la orden es para este equipo y no para otro,
  - y que no es vieja: una orden caduca en dos minutos, así que no se puede guardar
    una de hoy para reutilizarla mañana.

Si algo no cuadra, se ignora en silencio y queda escrito en el registro.

Aunque alguien lograra colar una orden válida, lo único que conseguiría es que este
equipo abra un túnel HACIA NUESTRO SERVIDOR, donde no entra sin la clave de acceso.
El timbre no da acceso: solo avisa.

  echo '<json>' | timbre_acceso.py
  timbre_acceso.py --b64 <orden en base64>
  timbre_acceso.py --generar-secreto
"""
import hashlib
import hmac
import json
import os
import subprocess
import sys
import time

SECRETO = '/etc/gesinne/timbre.key'
GUION = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'acceso_remoto.sh')
LOG = '/var/log/gesinne-acceso-remoto.log'
VALIDEZ_SEGUNDOS = 120


def registra(texto):
    linea = '%s timbre: %s' % (time.strftime('%F %T'), texto)
    try:
        with open(LOG, 'a') as f:
            f.write(linea + '\n')
    except Exception:
        pass
    print(linea)


def numero_equipo():
    import glob
    for f in glob.glob('/home/*/config/equipo_config.json'):
        try:
            with open(f) as cf:
                s = (json.load(cf) or {}).get('serie')
            if s:
                return str(s)
        except Exception:
            continue
    return None


def secreto():
    try:
        with open(SECRETO, 'rb') as f:
            return f.read().strip()
    except Exception:
        return None


def firma_de(datos, clave):
    """Se firma el mensaje sin el campo de la firma, en orden fijo: si se firmara el
    texto tal cual, cualquier reordenación de las claves daría otra firma."""
    copia = {k: v for k, v in datos.items() if k != 'firma'}
    canonico = json.dumps(copia, sort_keys=True, separators=(',', ':')).encode()
    return hmac.new(clave, canonico, hashlib.sha256).hexdigest()


def main():
    if '--generar-secreto' in sys.argv:
        os.makedirs('/etc/gesinne', exist_ok=True)
        nuevo = hashlib.sha256(os.urandom(32)).hexdigest().encode()
        with open(SECRETO, 'wb') as f:
            f.write(nuevo)
        os.chmod(SECRETO, 0o600)
        print(nuevo.decode())      # se registra en el servidor, junto a la clave del equipo
        return 0

    # El nodo exec de Node-RED pasa el mensaje como argumento, no por la entrada
    # estándar, y un JSON con comillas en una línea de comandos se rompe solo: por eso
    # viaja en base64.
    if '--b64' in sys.argv:
        import base64
        try:
            crudo = base64.b64decode(sys.argv[sys.argv.index('--b64') + 1]).decode()
        except Exception:
            registra('no he podido descifrar el base64 de la orden')
            return 1
    else:
        crudo = sys.stdin.read().strip()
    if not crudo:
        return 0
    try:
        orden = json.loads(crudo)
    except Exception:
        registra('orden ilegible, se ignora')
        return 1

    clave = secreto()
    if not clave:
        registra('este equipo no tiene secreto: %s no existe' % SECRETO)
        return 1

    esperada = firma_de(orden, clave)
    if not hmac.compare_digest(esperada, str(orden.get('firma', ''))):
        registra('firma que no cuadra, se ignora la orden')
        return 1

    mio = numero_equipo()
    if str(orden.get('equipo')) != str(mio):
        registra('orden dirigida al equipo %s, y este es el %s: se ignora'
                 % (orden.get('equipo'), mio))
        return 1

    edad = time.time() - float(orden.get('momento', 0))
    if not -30 < edad < VALIDEZ_SEGUNDOS:
        registra('orden caducada o con fecha rara (%.0f s): se ignora' % edad)
        return 1

    accion = orden.get('accion')
    if accion == 'cerrar':
        subprocess.run(['sudo', GUION, 'cerrar'], timeout=60)
        return 0
    if accion == 'abrir':
        cmd = ['sudo', GUION, 'abrir',
               str(orden.get('puerto_terminal', '')), str(orden.get('puerto_pantalla', '')),
               str(orden.get('minutos', 30))]
        subprocess.run([c for c in cmd if c != ''], timeout=120)
        return 0

    registra('orden desconocida: %r' % accion)
    return 1


if __name__ == '__main__':
    sys.exit(main())
