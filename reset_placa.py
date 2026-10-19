#!/usr/bin/env python3
"""
Reset remoto de placas por Modbus, con las secuencias REALES del firmware
(verificadas en Gesinne/FW, Events.c, v1.4.13).

    python3 reset_placa.py --ver                      # diagnostico, no escribe nada
    python3 reset_placa.py --slave 1 --reset          # reset normal (exige estado 0)
    python3 reset_placa.py --slave 1 --emergencia     # reset incondicional (v1.4.11+)

Secuencias (NO son las que usaba spam_reset.py):
  reset normal  -> reg 110 (FLAG_RST) = 0xCACA  y luego reg 111 = 0xCACA
                   el firmware RECHAZA cualquier otro valor en el 110, y el
                   111 solo actua si ESTADO_ACTUAL == 0 (placa parada).
  emergencia    -> reg 113 = 0xDEAD DOS veces seguidas. Sin llave previa y
                   sin exigir estado 0. Solo en firmware >= 1.4.11.

Por que existe el diagnostico: desde v1.4.11 el firmware arranca Modbus ANTES
de leer la FLASH, con direccion 1 y 115200 por defecto. Una placa que se
cuelgue en la cascada FLASH se queda contestando como SLAVE 1. Si L1 ya es la
1, hay DOS placas respondiendo a la vez: el bus se llena de tramas corruptas,
la fase colgada da 0 mensajes y las otras caen en picado. Eso se ve aqui como
muchos CRC malos en el slave 1 y silencio en el slave de la fase perdida.

ATENCION: parar Node-RED antes (sudo systemctl stop nodered); el puerto debe
estar libre (sudo lsof /dev/ttyAMA0 vacio).
"""
import argparse
import struct
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("falta pyserial: sudo apt install python3-serial")

CACA = 0xCACA   # 51908
DEAD = 0xDEAD   # 57005
FLAG_RST, REG_RESET, REG_EMER = 110, 111, 113
REG_VERSION, REG_ESTADO, REG_ALARMAS = 100, 0, 2
FASE = {1: "L1", 2: "L2", 3: "L3"}


def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def _tx(ser, pdu):
    ser.reset_input_buffer()
    ser.write(pdu + struct.pack("<H", crc16(pdu)))


def lee(ser, slave, addr):
    """Devuelve (valor, estado) con estado en {'ok','crc','excepcion','silencio'}."""
    _tx(ser, struct.pack(">BBHH", slave, 3, addr, 1))
    resp = ser.read(7)
    if not resp:
        return None, "silencio"
    if len(resp) >= 5 and resp[1] == 0x83:
        return None, "excepcion"
    if len(resp) < 7:
        return None, "crc"
    if crc16(resp[:5]) != struct.unpack("<H", resp[5:7])[0]:
        return None, "crc"
    return struct.unpack(">H", resp[3:5])[0], "ok"


def escribe(ser, slave, addr, valor):
    _tx(ser, struct.pack(">BBHH", slave, 6, addr, valor))
    resp = ser.read(8)
    if not resp:
        return "silencio"
    if len(resp) >= 5 and resp[1] == 0x86:
        return "excepcion %d" % resp[2]
    if len(resp) >= 8 and resp[0] == slave and resp[1] == 6:
        return "ok"
    return "respuesta rara (%s)" % resp.hex()


def diagnostico(ser, slaves, intentos):
    print("  slave  fase  ok   CRC malo  silencio  version  estado  alarmas")
    sospecha = {}
    for s in slaves:
        cuenta = {"ok": 0, "crc": 0, "excepcion": 0, "silencio": 0}
        ver = None
        for _ in range(intentos):
            v, st = lee(ser, s, REG_VERSION)
            cuenta[st] += 1
            if st == "ok":
                ver = v
            time.sleep(0.05)
        est, _ = lee(ser, s, REG_ESTADO)
        ala, _ = lee(ser, s, REG_ALARMAS)
        print("  %5d  %-4s  %-3d  %-8d  %-8d  %-7s  %-6s  %s" % (
            s, FASE.get(s, "?"), cuenta["ok"], cuenta["crc"], cuenta["silencio"],
            ver if ver is not None else "-",
            est if est is not None else "-",
            ("0x%04X" % ala) if ala is not None else "-"))
        sospecha[s] = cuenta
    print()
    colision = [s for s, c in sospecha.items()
                if c["crc"] >= max(2, intentos // 4) and c["ok"] < intentos]
    mudos = [s for s, c in sospecha.items() if c["ok"] == 0]
    if colision:
        print("  *** CRC malos en el slave %s: hay DOS placas contestando a la vez."
              % ", ".join(str(s) for s in colision))
        print("      Una placa colgada en la cascada FLASH se queda en direccion 1.")
        print("      Arreglo:  python3 reset_placa.py --slave %d --emergencia" % colision[0])
        print("      (resetea las dos; vuelven con su direccion real si la FLASH esta sana)")
    if mudos:
        print("  *** sin respuesta en el slave %s (fase %s)."
              % (", ".join(str(s) for s in mudos),
                 ", ".join(FASE.get(s, "?") for s in mudos)))
    if not colision and not mudos:
        print("  las tres placas contestan limpias.")
    return colision, mudos


BAUDS = [38400, 115200, 57600, 19200, 9600]


def barrido(puerto, slaves, intentos):
    """Prueba cada velocidad contra cada slave. No escribe nada."""
    print("=== barrido de velocidades en %s ===" % puerto)
    print("  (silencio en TODAS = el bus no habla: alimentacion, par cortado o")
    print("   transceptor; respuestas en una = esa es la velocidad real)\n")
    encontrado = []
    for baud in BAUDS:
        try:
            ser = serial.Serial(puerto, baud, timeout=0.4)
        except Exception as e:
            print("  %6d  no se pudo abrir: %s" % (baud, e))
            continue
        time.sleep(0.15)
        linea = []
        for s in slaves:
            ok = crc = 0
            for _ in range(intentos):
                v, st = lee(ser, s, REG_VERSION)
                if st == "ok":
                    ok += 1
                elif st == "crc":
                    crc += 1
                time.sleep(0.03)
            linea.append("%s:%d ok/%d crc" % (FASE.get(s, s), ok, crc))
            if ok:
                encontrado.append((baud, s, ok))
        print("  %6d   %s" % (baud, "   ".join(linea)))
        ser.close()
    print()
    if encontrado:
        print("  *** CONTESTAN:")
        for baud, s, ok in encontrado:
            print("      %s a %d baud (%d respuestas buenas)" % (FASE.get(s, s), baud, ok))
    else:
        print("  *** silencio en las 5 velocidades y los 3 slaves.")
        print("      No es un problema de velocidad. Siguiente: alimentacion de las")
        print("      placas, continuidad del par A/B, y contadores del UART")
        print("      (sudo cat /proc/tty/driver/ttyAMA dos veces separadas 1 min:")
        print("       si tx sube y rx NO, el transceptor no oye).")
    return encontrado


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--puerto", default="/dev/ttyAMA0")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--slave", type=int)
    p.add_argument("--slaves", default="1,2,3", help="para --ver")
    p.add_argument("--intentos", type=int, default=8)
    p.add_argument("--ver", action="store_true", help="solo diagnostico")
    p.add_argument("--barrer", action="store_true",
                   help="prueba todas las velocidades x slaves (no escribe nada)")
    p.add_argument("--reset", action="store_true", help="110=0xCACA + 111=0xCACA")
    p.add_argument("--emergencia", action="store_true", help="113=0xDEAD x2")
    a = p.parse_args()

    if not (a.ver or a.reset or a.emergencia or a.barrer):
        a.ver = True

    if a.barrer:
        barrido(a.puerto, [int(x) for x in a.slaves.split(",")], max(3, a.intentos // 2))
        return

    ser = serial.Serial(a.puerto, a.baud, timeout=0.4)
    time.sleep(0.2)
    try:
        if a.ver:
            print("=== diagnostico en %s @ %d ===" % (a.puerto, a.baud))
            diagnostico(ser, [int(x) for x in a.slaves.split(",")], a.intentos)
            return

        if not a.slave:
            sys.exit("indica --slave")

        est, st = lee(ser, a.slave, REG_ESTADO)
        print("  estado actual del slave %d: %s" % (a.slave, est if st == "ok" else st))

        if a.emergencia:
            print("  EMERGENCY RESET: reg %d = 0x%04X, dos veces" % (REG_EMER, DEAD))
            print("   1a escritura (arma): %s" % escribe(ser, a.slave, REG_EMER, DEAD))
            time.sleep(0.1)
            print("   2a escritura (resetea): %s" % escribe(ser, a.slave, REG_EMER, DEAD))
            print("  (la placa no contesta mientras arranca; es normal)")
        else:
            if est not in (0, None) and st == "ok":
                print("  AVISO: el estado es %d, no 0. El firmware RECHAZARA el reset" % est)
                print("  del 111. Para una placa en marcha usa --emergencia.")
            print("  arma el reset: reg %d = 0x%04X -> %s"
                  % (FLAG_RST, CACA, escribe(ser, a.slave, FLAG_RST, CACA)))
            time.sleep(0.1)
            print("  ejecuta:       reg %d = 0x%04X -> %s"
                  % (REG_RESET, CACA, escribe(ser, a.slave, REG_RESET, CACA)))

        print("\n  esperando 6 s a que arranque...")
        time.sleep(6)
        print("=== despues del reset ===")
        diagnostico(ser, [1, 2, 3], 6)
    finally:
        ser.close()


if __name__ == "__main__":
    main()
