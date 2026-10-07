#!/usr/bin/env python3
"""
Espabila las placas ChopperAC por BROADCAST cuando el bus esta mudo.

CUANDO USARLO: las placas no contestan a las lecturas (silencio total, ni un
byte) pero el bus esta bien y la velocidad es la correcta. Un broadcast Modbus
(slave 0) NO espera respuesta, asi que llega aunque no podamos leer nada.

QUE MANDA: la misma secuencia que la opcion 12 del menu de install.sh --
reg 30 = 43981 y reg 40 = 47818 (las dos llaves de desbloqueo de escritura),
y luego reg 31 con el estado pedido. Las tres en la MISMA sesion de puerto:
las llaves caducan, y lanzarlas con comandos separados no funciona.

DIFERENCIA CON LA OPCION 12 DEL MENU: aquella se conecta a 115200 fijo. Si el
bus va a otra velocidad (38400 es habitual), las placas no oyen el broadcast y
parece que no reaccionan. Aqui el baudrate se elige, y con --barrer se prueban
todos.

OJO: reg 31 = 0 deja las placas en BYPASS, o sea el equipo DEJA DE REGULAR
(estado seguro, pero el cliente pierde el ahorro mientras siga asi). Para
devolverlas a regulacion: --estado 2. El script lo recuerda al terminar.

Uso:
    sudo systemctl stop nodered          # imprescindible: el puerto es de uno solo
    python3 espabila_placas.py                        # bypass a 38400 y informe
    python3 espabila_placas.py --barrer               # prueba 38400/115200/57600
    python3 espabila_placas.py --estado 2             # devolver a REGULACION
    python3 espabila_placas.py --solo-leer            # no escribe nada
"""
import argparse
import struct
import sys
import time

import serial

BAUDS_HABITUALES = (38400, 115200, 57600)
LLAVE_30 = 43981   # 0xABCD
LLAVE_40 = 47818   # 0xBACA
REG_ESTADO = 31
TAG_ESTADO = {0: "BYPASS", 1: "OFF", 2: "REGULACION"}


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def _con_crc(pdu: bytes) -> bytes:
    return pdu + struct.pack("<H", crc16(pdu))


def trama_write(slave: int, addr: int, val: int) -> bytes:
    """FC=6, escribir un registro."""
    return _con_crc(struct.pack(">BBHH", slave, 6, addr, val))


def trama_read(slave: int, addr: int, qty: int = 1) -> bytes:
    """FC=3, leer holding registers."""
    return _con_crc(struct.pack(">BBHH", slave, 3, addr, qty))


def lee_reg(ser, slave: int, addr: int, intentos: int = 3):
    """Devuelve el valor, o None si no contesta / contesta mal."""
    for _ in range(intentos):
        ser.reset_input_buffer()
        ser.write(trama_read(slave, addr))
        resp = ser.read(7)
        if len(resp) == 7 and resp[0] == slave and resp[1] == 3:
            if crc16(resp[:-2]) == struct.unpack("<H", resp[-2:])[0]:
                return struct.unpack(">H", resp[3:5])[0]
        time.sleep(0.1)
    return None


def manda_broadcast(ser, estado: int, verbose=True):
    """Secuencia completa de desbloqueo + estado, a slave 0 (sin respuesta)."""
    for addr, val in ((30, LLAVE_30), (40, LLAVE_40), (REG_ESTADO, estado)):
        if verbose:
            print("      reg %d = %d" % (addr, val))
        ser.write(trama_write(0, addr, val))
        ser.flush()
        time.sleep(0.2)


def foto(ser, slaves, etiqueta):
    print("  %s:" % etiqueta)
    estado = {}
    for sl in slaves:
        v = lee_reg(ser, sl, REG_ESTADO)
        estado[sl] = v
        if v is None:
            print("    L%d: sin respuesta" % sl)
        else:
            print("    L%d: reg31=%d (%s)" % (sl, v, TAG_ESTADO.get(v, "valor=%d" % v)))
    return estado


def intento(port, baud, estado, slaves, solo_leer):
    print("")
    print("  ── %d baud ──" % baud)
    try:
        ser = serial.Serial(port, baud, timeout=0.3)
    except serial.SerialException as e:
        print("  [X] no se pudo abrir %s: %s" % (port, e))
        return None, None
    with ser:
        antes = foto(ser, slaves, "ANTES")
        if solo_leer:
            return antes, antes
        print("  [B] BROADCAST (slave=0):")
        manda_broadcast(ser, estado)
        print("  [~] esperando 2s a que procesen...")
        time.sleep(2)
        despues = foto(ser, slaves, "DESPUES")
    return antes, despues


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", default="/dev/ttyAMA0")
    p.add_argument("--baud", type=int, default=38400)
    p.add_argument("--barrer", action="store_true",
                   help="probar la secuencia en %s" % (BAUDS_HABITUALES,))
    p.add_argument("--estado", type=int, default=0, choices=(0, 1, 2),
                   help="valor para reg 31: 0=BYPASS (por defecto), 2=REGULACION")
    p.add_argument("--slaves", default="1,2,3")
    p.add_argument("--solo-leer", action="store_true", help="no escribe nada")
    args = p.parse_args()

    slaves = [int(s) for s in args.slaves.split(",")]
    bauds = BAUDS_HABITUALES if args.barrer else (args.baud,)

    print("[*] Puerto %s | slaves %s | reg31 -> %d (%s)%s"
          % (args.port, slaves, args.estado,
             TAG_ESTADO.get(args.estado, "?"),
             "  [SOLO LECTURA]" if args.solo_leer else ""))

    recuperadas_total = {}
    for baud in bauds:
        antes, despues = intento(args.port, baud, args.estado, slaves, args.solo_leer)
        if despues is None:
            sys.exit(1)
        vivas = [sl for sl, v in despues.items() if v is not None]
        if vivas:
            recuperadas_total[baud] = vivas
            nuevas = [sl for sl in vivas if antes.get(sl) is None]
            if nuevas:
                print("  [OK] contestan tras el broadcast y antes no: %s"
                      % ", ".join("L%d" % s for s in nuevas))
            if not args.barrer:
                break

    print("")
    print("=" * 64)
    if not recuperadas_total:
        print("  Ninguna placa contesta a ninguna velocidad probada.")
        print("  El broadcast se ha enviado igualmente (no espera respuesta),")
        print("  asi que si alguna estaba atascada deberia haber reaccionado.")
        print("  Siguiente paso: nivel fisico (tierra comun, terminacion, tension).")
    else:
        for baud, vivas in recuperadas_total.items():
            print("  @ %d baud contestan: %s" % (baud, ", ".join("L%d" % s for s in vivas)))
        if args.estado == 0 and not args.solo_leer:
            print("")
            print("  [!]  Las placas quedan en BYPASS: el equipo NO esta regulando.")
            print("       Para devolverlas a regulacion:")
            print("       python3 espabila_placas.py --estado 2 --baud %d" % list(recuperadas_total)[0])
    print("  Acuerdate de arrancar Node-RED:  sudo systemctl start nodered")
    print("=" * 64)


if __name__ == "__main__":
    main()
