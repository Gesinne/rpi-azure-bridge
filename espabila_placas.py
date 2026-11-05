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

RESET A CIEGAS (--reset): manda ademas reg 110 y reg 111 = 0xCACA, que es el
reset del firmware. Es la UNICA via remota en placas con fw < 1.4.11: esas no
tienen el reset de emergencia del reg 113 ni se quedan contestando como slave 1
cuando se cuelgan, asi que no hay forma de leerlas ni de rescatarlas leyendo.
El reg 111 solo actua con ESTADO_ACTUAL = 0, por eso la secuencia pasa primero
por BYPASS; con --estado 2 se las devuelve a regulacion despues del reset.

Uso:
    sudo systemctl stop nodered          # imprescindible: el puerto es de uno solo
    python3 espabila_placas.py                        # bypass a 38400 y informe
    python3 espabila_placas.py --barrer               # prueba 38400/115200/57600
    python3 espabila_placas.py --estado 2             # devolver a REGULACION
    python3 espabila_placas.py --solo-leer            # no escribe nada
    python3 espabila_placas.py --reset --barrer        # reset a ciegas (fw < 1.4.11)
    python3 espabila_placas.py --reset --estado 2      # reset y dejarlas regulando
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
LLAVE_RST = 51908  # 0xCACA: vale como llave (reg 110) y como orden de reset (reg 111)
REG_FLAG_RST = 110
REG_RESET_FW = 111
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


def manda_reset_broadcast(ser, verbose=True):
    """Reset del firmware a ciegas, a slave 0 (no espera respuesta).

    El reg 111 solo actua si ESTADO_ACTUAL = 0, asi que la secuencia pasa por
    BYPASS antes de resetear. Las llaves caducan al cerrar el puerto, de modo
    que las cinco escrituras van en la MISMA sesion.
    """
    pasos = ((30, LLAVE_30), (40, LLAVE_40), (REG_ESTADO, 0),
             (REG_FLAG_RST, LLAVE_RST), (REG_RESET_FW, LLAVE_RST))
    for addr, val in pasos:
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


def intento(port, baud, estado, slaves, solo_leer, reset=False, espera=6):
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
        if reset:
            print("  [R] RESET por BROADCAST (slave=0):")
            manda_reset_broadcast(ser)
            print("  [~] esperando %ds a que arranquen..." % espera)
            time.sleep(espera)
            despues = foto(ser, slaves, "DESPUES DEL RESET")
            # El reset las deja en bypass. Si se pide regulacion, se manda ahora:
            # una placa recien arrancada no regula hasta que se le dice.
            if estado != 0:
                print("  [B] BROADCAST de estado (slave=0):")
                manda_broadcast(ser, estado)
                time.sleep(2)
                despues = foto(ser, slaves, "DESPUES")
            return antes, despues
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
    p.add_argument("--reset", action="store_true",
                   help="manda tambien el reset del firmware (reg 110+111); para fw < 1.4.11")
    p.add_argument("--espera", type=int, default=6,
                   help="segundos tras el reset antes de releer (por defecto 6)")
    args = p.parse_args()

    slaves = [int(s) for s in args.slaves.split(",")]
    bauds = BAUDS_HABITUALES if args.barrer else (args.baud,)

    print("[*] Puerto %s | slaves %s | reg31 -> %d (%s)%s%s"
          % (args.port, slaves, args.estado,
             TAG_ESTADO.get(args.estado, "?"),
             "  [CON RESET]" if args.reset and not args.solo_leer else "",
             "  [SOLO LECTURA]" if args.solo_leer else ""))

    recuperadas_total = {}
    for baud in bauds:
        antes, despues = intento(args.port, baud, args.estado, slaves, args.solo_leer,
                                 args.reset, args.espera)
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
        if args.reset:
            print("  El reset (reg 110+111) tambien se ha enviado a ciegas. Si tras esto")
            print("  siguen mudas, no queda via remota: con fw < 1.4.11 no hay reset de")
            print("  emergencia, y solo lo levanta un corte de tension del equipo o una visita.")
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
