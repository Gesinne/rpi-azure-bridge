#!/usr/bin/env python3
"""
Escaner Modbus EXTENDIDO: prueba ademas paridad/stop bits no estandar.

Ultimo intento antes de dar por perdida una PCB que no responde a
ningun ID/baud estandar.

Uso (parar Node-RED antes):
    sudo systemctl stop nodered
    python3 scan_modbus_extendido.py
    sudo systemctl start nodered
"""
import argparse
import serial
import struct
import sys
import time


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def lee_registro(ser, slave, addr, intentos=2):
    for _ in range(intentos):
        pdu = struct.pack(">BBHH", slave, 3, addr, 1)
        try:
            ser.reset_input_buffer()
            ser.write(pdu + struct.pack("<H", crc16(pdu)))
            resp = ser.read(7)
            if len(resp) >= 7 and resp[0] == slave and resp[1] == 3:
                payload = resp[:-2]
                crc_rx = struct.unpack("<H", resp[-2:])[0]
                if crc16(payload) == crc_rx:
                    return struct.unpack(">H", resp[3:5])[0]
        except Exception:
            pass
    return None


# Configuraciones serie a probar (baud, parity, stopbits)
CONFIGS = [
    # Estandar Modbus RTU
    (115200, "N", 1),
    (38400, "N", 1),
    (19200, "N", 1),
    (9600, "N", 1),
    (57600, "N", 1),
    # Paridad even (variante comun)
    (9600, "E", 1),
    (19200, "E", 1),
    (38400, "E", 1),
    # Paridad odd
    (9600, "O", 1),
    (19200, "O", 1),
    # 2 stop bits (algunas implementaciones legacy)
    (9600, "N", 2),
    (19200, "N", 2),
    # Otras velocidades poco comunes
    (4800, "N", 1),
    (2400, "N", 1),
    (1200, "N", 1),
]

PARIDADES = {"N": serial.PARITY_NONE, "E": serial.PARITY_EVEN, "O": serial.PARITY_ODD}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", default="/dev/ttyAMA0")
    p.add_argument("--ids", default="1,2,3", help="IDs a probar (ej 1,2,3 o 1-247)")
    p.add_argument("--reg", type=int, default=0)
    p.add_argument("--timeout", type=float, default=0.2)
    args = p.parse_args()

    if "-" in args.ids:
        a, b = args.ids.split("-")
        ids = list(range(int(a), int(b)+1))
    else:
        ids = [int(x.strip()) for x in args.ids.split(",")]

    print(f"[*] Puerto: {args.port}")
    print(f"[*] Slave IDs: {ids}")
    print(f"[*] Configuraciones a probar: {len(CONFIGS)}")
    print()

    encontrados = []
    for baud, parity, stop in CONFIGS:
        cfg = f"{baud} bps {parity} {stop}stop"
        print(f"  --- Probando {cfg} ---", file=sys.stderr)
        try:
            ser = serial.Serial(args.port, baud,
                                parity=PARIDADES[parity],
                                stopbits=stop,
                                timeout=args.timeout)
        except Exception as e:
            print(f"  [X] {e}", file=sys.stderr)
            continue

        for sl in ids:
            v = lee_registro(ser, sl, args.reg)
            if v is not None:
                print(f"  [OK] Slave {sl} a {cfg}: reg {args.reg}={v}",
                      file=sys.stderr)
                encontrados.append((sl, baud, parity, stop, v))
            time.sleep(0.005)

        ser.close()

    print()
    print("=" * 70)
    print("  RESULTADO ESCANEO EXTENDIDO")
    print("=" * 70)
    if encontrados:
        for sl, baud, par, stop, v in encontrados:
            print(f"  Slave {sl:>3}  @ {baud:>6} bps {par} {stop}stop  reg={v}")
    else:
        print("  Sin respuestas en ningun ID ni configuracion serie.")
        print()
        print("  Veredicto final:")
        print("  Las PCBs estan fisicamente desconectadas del bus o el")
        print("  transceptor RS-485 esta danado. NO recuperable desde RPi.")
    print("=" * 70)


if __name__ == "__main__":
    main()
