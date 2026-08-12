#!/usr/bin/env python3
"""
Aviso de cambio de placa / FW tras reinicio.

Al arrancar la RPi (crontab @reboot) lee el Nº de serie (reg 41) y la versión de
FW (reg 100) de las 3 placas de fase (L1/L2/L3), lo compara con el último snapshot
guardado y, si algo cambió (placa sustituida, FW actualizado, o una placa que deja
de responder / aparece), envía un email a través de enviar_email.py.

- Lector RAW serial (pyserial + CRC16), el mismo método probado del menú
  "Leer placa con raw serial" — no depende de pymodbus.
- Se lanza por systemd MUY PRONTO en el arranque, ANTES de docker/nodered, así el
  puerto /dev/ttyAMA0 está libre (lo coge el contenedor gesinne-rpi) y NO hay que
  parar Node-RED — se lee rápido y se sigue. (After=network-online → email OK.)
- El primer arranque solo guarda el snapshot (no avisa).
- Salvaguardas anti-falsos-positivos: si NINGUNA placa responde (contención/boot
  raro) no avisa ni pisa el snapshot; "deja de responder" solo avisa si alguna otra
  fase SÍ respondió (prueba de que el bus va).

Snapshot: /var/lib/gesinne/placas_snapshot.json (override con env SNAP_FILE).
"""
import sys, os, time, json, socket

SNAP = os.environ.get('SNAP_FILE', '/var/lib/gesinne/placas_snapshot.json')
BRIDGE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BRIDGE_DIR)

try:
    import serial
except ImportError:
    print("[aviso] pyserial no instalado"); sys.exit(0)


def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = ((crc >> 1) ^ 0xA001) if (crc & 1) else (crc >> 1)
    return crc


def build_read_req(slave, addr, count=1):
    req = bytes([slave, 0x03, (addr >> 8) & 0xFF, addr & 0xFF,
                 (count >> 8) & 0xFF, count & 0xFF])
    c = crc16(req)
    return req + bytes([c & 0xFF, (c >> 8) & 0xFF])


def parse_response(buf, slave, count=1):
    exp = 5 + 2 * count
    for start in range(len(buf) - exp + 1):
        f = buf[start:start + exp]
        if f[0] != slave or f[1] != 0x03 or f[2] != 2 * count:
            continue
        if crc16(f[:-2]) != (f[-2] | (f[-1] << 8)):
            continue
        return [(f[3 + 2 * i] << 8) | f[3 + 2 * i + 1] for i in range(count)]
    return None


def read_register(ser, slave, addr, timeout=2.0):
    ser.reset_input_buffer()
    ser.write(build_read_req(slave, addr))
    ser.flush()
    buf = b''
    t0 = time.time()
    while time.time() - t0 < timeout:
        data = ser.read(256)
        if data:
            buf += data
            r = parse_response(buf, slave)
            if r is not None:
                return r[0]
        elif buf and time.time() - t0 > 0.4:
            r = parse_response(buf, slave)
            if r is not None:
                return r[0]
    return None


def find_port():
    for p in ['/dev/ttyAMA0', '/dev/serial0', '/dev/ttyUSB0', '/dev/ttyACM0', '/dev/ttyS0']:
        if os.path.exists(p):
            return p
    return None


def leer_placas():
    """Devuelve {'L1': {'serie':x,'fw':y} | None, ...} o None si no hay puerto."""
    port = find_port()
    if not port:
        return None
    # Autodetecta baudrate probando slave 1 (reg 0) a las 3 velocidades válidas.
    ser = None
    for baud in (115200, 57600, 38400):
        s = serial.Serial(port, baudrate=baud, bytesize=8, parity='N', stopbits=1, timeout=0.2)
        if read_register(s, 1, 0, timeout=1.5) is not None:
            ser = s
            break
        s.close()
    if ser is None:
        ser = serial.Serial(port, baudrate=115200, bytesize=8, parity='N', stopbits=1, timeout=0.2)
    estado = {}
    for slave in (1, 2, 3):
        serie = read_register(ser, slave, 41, timeout=2.0)
        fw = read_register(ser, slave, 100, timeout=2.0) if serie is not None else None
        estado['L%d' % slave] = ({'serie': serie, 'fw': fw} if serie is not None else None)
    ser.close()
    return estado


def diff(prev, actual):
    cambios = []
    for L in ('L1', 'L2', 'L3'):
        a, p = actual.get(L), prev.get(L)
        if a == p:
            continue
        if p and not a:
            cambios.append("%s: DEJA DE RESPONDER (antes serie %s, FW %s)" % (L, p.get('serie'), p.get('fw')))
        elif a and not p:
            cambios.append("%s: AHORA RESPONDE (serie %s, FW %s)" % (L, a.get('serie'), a.get('fw')))
        else:
            if p.get('serie') != a.get('serie'):
                cambios.append("%s: CAMBIO DE PLACA — Nº serie %s → %s" % (L, p.get('serie'), a.get('serie')))
            if p.get('fw') != a.get('fw'):
                cambios.append("%s: CAMBIO DE FW — %s → %s" % (L, p.get('fw'), a.get('fw')))
    return cambios


def main():
    # Se lee directamente: por el orden systemd (antes de docker/nodered) el puerto
    # está libre y no hay que parar nada.
    actual = leer_placas()
    if actual is None:
        print("[aviso] sin puerto serie"); return

    # Salvaguarda: si NINGUNA placa respondió, no es fiable (contención/arranque) →
    # no avisar ni pisar el snapshot bueno.
    if not any(actual.get(L) for L in ('L1', 'L2', 'L3')):
        print("[aviso] ninguna placa respondió — no se toca el snapshot ni se avisa"); return

    prev = None
    try:
        with open(SNAP) as f:
            prev = json.load(f)
    except Exception:
        prev = None

    try:
        os.makedirs(os.path.dirname(SNAP), exist_ok=True)
        with open(SNAP, 'w') as f:
            json.dump(actual, f)
    except Exception as e:
        print("[aviso] no se pudo guardar snapshot:", e)

    if prev is None:
        print("[aviso] primer snapshot guardado, sin comparación"); return

    cambios = diff(prev, actual)
    if not cambios:
        print("[aviso] sin cambios de placa/FW"); return

    equipo = socket.gethostname()
    cuerpo = ("Tras el reinicio de la RPi (%s) se han detectado cambios en las placas:\n\n"
              % equipo)
    cuerpo += "\n".join("  - " + c for c in cambios)
    cuerpo += "\n\nEstado actual (Nº serie / FW por fase):\n"
    for L in ('L1', 'L2', 'L3'):
        v = actual.get(L)
        cuerpo += "  %s: %s\n" % (L, ("serie %s, FW %s" % (v.get('serie'), v.get('fw')) if v else "no responde"))
    cuerpo += "\nFecha: %s\n" % time.strftime('%Y-%m-%d %H:%M:%S')

    try:
        from enviar_email import enviar_email
    except Exception as e:
        print("[aviso] no se pudo importar enviar_email:", e); return
    # Reintentos: arrancamos pronto en el boot, la red puede tardar en estar lista.
    asunto = "⚠️ Cambio de placa/FW tras reinicio · %s" % equipo
    for intento in range(1, 6):
        try:
            enviar_email(cuerpo, asunto=asunto, numero_serie=equipo)
            print("[aviso] email enviado:", cambios); return
        except Exception as e:
            print("[aviso] email intento %d falló: %s" % (intento, e))
            time.sleep(15)
    print("[aviso] no se pudo enviar el email tras varios intentos")


if __name__ == '__main__':
    main()
