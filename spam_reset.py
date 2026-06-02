#!/usr/bin/env python3
"""
Spammer de broadcast reset: envia 200 resets seguidos con micropausa.

Si el bus tiene CRC malos, alguna pasara intacta y reseteara las PCBs.

Uso (con Node-RED parado):
    python3 spam_reset.py --reg 110 --valor 1 --n 200 --baud 115200
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
