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
BAUDRATES_PROBE = [115200, 57600, 38400, 19200, 9600]
SLAVES_PROBE = (1, 2, 3)
PROBE_REGISTER = 0          # Registro 0 = Estado actual del chopper (siempre presente)
PROBE_TIMEOUT = 0.6         # Segundos por intento (5 baudrates × 3 slaves × 0.6 ≈ 9s peor caso)


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
    """Detecta el baudrate al que responde la placa Modbus.

    - Si `force` es int, se devuelve sin probar.
    - Si hay cache válido, se prueba primero (corto-circuita la lista).
    - Si nada responde, devuelve DEFAULT_BAUDRATE (115200) sin escribir cache.
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
    """Devuelve un ModbusSerialClient con baudrate autodetectado.

    El cliente se devuelve SIN llamar a .connect() — el caller decide cuándo.
    Si no hay forma de detectar (placas apagadas/sin respuesta), usa 115200.
    """
    br = detect_baudrate(port, force=force_baudrate)
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
