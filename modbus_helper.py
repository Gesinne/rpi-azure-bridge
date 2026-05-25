#!/usr/bin/env python3
"""
Helper Modbus: abre cliente serial con autodetección de baudrate y cache.

Si alguien cambia la velocidad Modbus de las placas (registro 47/61), este
helper la detecta en runtime probando una lista de baudrates y cachea el
que funciona en un fichero JSON, para que la próxima vez no penalice.

Uso típico:
    from modbus_helper import open_modbus_client
    client = open_modbus_client()  # puerto y baudrate por defecto
    if client.connect():
        ...

Cache: /home/<user>/config/baudrate_cache.json
Formato: {"port": "/dev/ttyAMA0", "baudrate": 115200, "ts": "<iso8601>"}
"""
import glob
import json
import os
from datetime import datetime

DEFAULT_PORT = "/dev/ttyAMA0"
DEFAULT_BAUDRATE = 115200
BAUDRATES_PROBE = [115200, 57600, 38400]   # registro 61 valores 0=115200, 1=57600, 2=38400
SLAVES_PROBE = (1,)         # Solo slave 1: si está apagado, los demás también.
PROBE_REGISTER = 0          # Registro 0 = Estado actual del chopper (siempre presente)
PROBE_TIMEOUT = 0.3         # 3 baudrates × 1 slave × 0.3 ≈ 0.9s peor caso (solo cache miss)


def _cache_path():
    """Busca el primer /home/<user>/config existente, o /tmp como fallback."""
    for p in glob.glob('/home/*/config'):
        if os.path.isdir(p):
            return os.path.join(p, 'baudrate_cache.json')
    # Fallback si no hay /home/<user>/config (ej. dev container)
    return '/tmp/baudrate_cache.json'


def _read_cache(port):
    """Devuelve el baudrate cacheado para `port`, o None si no hay/no aplica."""
    try:
        path = _cache_path()
        if not os.path.isfile(path):
            return None
        with open(path) as f:
            data = json.load(f)
        if data.get('port') == port:
            br = data.get('baudrate')
            if isinstance(br, int) and br in BAUDRATES_PROBE:
                return br
    except Exception:
        pass
    return None


def _write_cache(port, baudrate):
    """Persiste el baudrate detectado. Errores silenciados (no es crítico)."""
    try:
        path = _cache_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w') as f:
            json.dump({
                'port': port,
                'baudrate': baudrate,
                'ts': datetime.utcnow().isoformat() + 'Z'
            }, f, indent=2)
    except Exception:
        pass


def _make_client(port, baudrate, timeout=1):
    """Construye un ModbusSerialClient compatible con pymodbus 2.x y 3.x."""
    try:
        from pymodbus.client import ModbusSerialClient
    except ImportError:
        from pymodbus.client.sync import ModbusSerialClient
    return ModbusSerialClient(
        port=port,
        baudrate=baudrate,
        bytesize=8,
        parity='N',
        stopbits=1,
        timeout=timeout
    )


def _probe_baudrate(port, baudrate, slaves=SLAVES_PROBE):
    """Devuelve True si algún slave responde al baudrate dado.

    Importante: pymodbus 3.7+ exige keyword-only (address=, count=, slave=).
    """
    client = _make_client(port, baudrate, timeout=PROBE_TIMEOUT)
    try:
        if not client.connect():
            return False
        for slave in slaves:
            try:
                # Compatibilidad pymodbus 2.x (unit=) y 3.x (slave=)
                try:
                    rr = client.read_holding_registers(address=PROBE_REGISTER, count=1, slave=slave)
                except TypeError:
                    rr = client.read_holding_registers(address=PROBE_REGISTER, count=1, unit=slave)
                if rr is not None and not getattr(rr, 'isError', lambda: True)():
                    return True
            except Exception:
                continue
        return False
    finally:
        try:
            client.close()
        except Exception:
            pass


def detect_baudrate(port=DEFAULT_PORT, force=None):
    """Detecta el baudrate al que responde la placa Modbus PROBANDO los puertos.

    Esta función SIEMPRE prueba — es la operación cara. Solo se debe llamar
    cuando no hay cache o cuando el cache ha fallado.
    """
    if isinstance(force, int):
        return force

    cached = _read_cache(port)
    order = []
    if cached:
        order.append(cached)
    for br in BAUDRATES_PROBE:
        if br != cached:
            order.append(br)

    for br in order:
        if _probe_baudrate(port, br):
            if br != cached:
                _write_cache(port, br)
            return br

    # Ningún baudrate responde: devolvemos default sin tocar cache.
    return DEFAULT_BAUDRATE


def open_modbus_client(port=DEFAULT_PORT, force_baudrate=None, timeout=1):
    """Devuelve un ModbusSerialClient listo para .connect().

    Path normal (cache hit): NO prueba nada, solo lee el baudrate cacheado
    y devuelve el cliente inmediatamente. El caller hace .connect() y lee.
    Coste casi cero — equivalente a la versión hardcoded original.

    Path lento (cache miss): detecta probando [115200..9600], cachea el
    que funcione, devuelve cliente. Solo ocurre la primera vez (o tras
    haber borrado el cache con `python3 modbus_helper.py --clear`).

    Si el cliente devuelto falla al conectar/leer porque alguien cambió
    la velocidad de la placa, el caller puede llamar a
    `redetect_and_open_modbus_client()` para forzar nueva detección.
    """
    if isinstance(force_baudrate, int):
        return _make_client(port, force_baudrate, timeout=timeout)

    cached = _read_cache(port)
    if cached:
        # Path rápido: confiamos en el cache. Si la placa ya no responde,
        # el .connect()/lectura del caller fallará y podrá redetectar.
        return _make_client(port, cached, timeout=timeout)

    # Primera vez (sin cache): detección completa.
    br = detect_baudrate(port)
    return _make_client(port, br, timeout=timeout)


def redetect_and_open_modbus_client(port=DEFAULT_PORT, timeout=1):
    """Borra cache y vuelve a detectar. Para usar cuando el cache es stale."""
    try:
        os.remove(_cache_path())
    except FileNotFoundError:
        pass
    except Exception:
        pass
    br = detect_baudrate(port)
    return _make_client(port, br, timeout=timeout)


def get_current_baudrate(port=DEFAULT_PORT):
    """Lee el baudrate cacheado sin hacer detección. Útil para logs."""
    return _read_cache(port) or DEFAULT_BAUDRATE


if __name__ == '__main__':
    # CLI: python3 modbus_helper.py [--port /dev/ttyAMA0] [--detect]
    import argparse
    p = argparse.ArgumentParser(description='Modbus baudrate helper')
    p.add_argument('--port', default=DEFAULT_PORT)
    p.add_argument('--detect', action='store_true', help='Forzar detección ahora')
    p.add_argument('--clear', action='store_true', help='Borrar cache de baudrate')
    args = p.parse_args()

    if args.clear:
        try:
            os.remove(_cache_path())
            print(f"Cache borrado: {_cache_path()}")
        except FileNotFoundError:
            print(f"No había cache en {_cache_path()}")
        raise SystemExit(0)

    if args.detect:
        print(f"Detectando baudrate en {args.port}...")
        br = detect_baudrate(args.port)
        print(f"  Baudrate detectado: {br}")
        print(f"  Cache: {_cache_path()}")
    else:
        print(f"Baudrate actual (cache): {get_current_baudrate(args.port)}")
        print(f"Cache: {_cache_path()}")
