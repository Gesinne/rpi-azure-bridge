#!/usr/bin/env python3
"""
OBSOLETO - NO USAR PARA RESETEAR. Usa reset_placa.py.

El ejemplo de abajo (--reg 110 --valor 1) NO resetea nada: el registro 110 es
FLAG_RST, la LLAVE del reset, y el firmware solo acepta en el 0xCACA (51908).
Cualquier otro valor se rechaza con MB_ILLEGAL_DATA_VALUE, asi que las 200
escrituras no armaban nada. Verificado en Gesinne/FW, Events.c.

Secuencia real: 110=0xCACA, luego 111=0xCACA (y exige ESTADO_ACTUAL=0),
o bien 113=0xDEAD dos veces (incondicional, firmware >= 1.4.11).
"""

import argparse
import serial
import struct
import time
import sys


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", default="/dev/ttyAMA0")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--slave", type=int, default=0, help="0 = broadcast")
    p.add_argument("--reg", type=int, default=110)
    p.add_argument("--valor", type=int, default=1)
    p.add_argument("--n", type=int, default=200)
    p.add_argument("--gap", type=float, default=0.05,
                   help="Pausa entre envios (segundos)")
    args = p.parse_args()

    ser = serial.Serial(args.port, args.baud, timeout=0.05)

    pdu = struct.pack(">BBHH", args.slave, 6, args.reg, args.valor)
    frame = pdu + struct.pack("<H", crc16(pdu))

    print(f"[*] Enviando {args.n} broadcasts a slave {args.slave}, reg {args.reg}={args.valor}")
    print(f"[*] Cada {args.gap*1000:.0f} ms, total {args.n*args.gap:.1f} segundos")

    for i in range(args.n):
        ser.reset_input_buffer()
        ser.write(frame)
        time.sleep(args.gap)
        if (i + 1) % 20 == 0:
            print(f"  {i+1}/{args.n}", file=sys.stderr)

    print(f"[*] Terminado. Espera 30s y vuelve a escanear.")


if __name__ == "__main__":
    main()
