#!/usr/bin/env python3
"""
Escribe un registro Modbus FC=6 a un slave.

Uso:
    python3 escribe_registro.py --slave 3 --reg 63 --valor 179

    Con baud distinto:
    python3 escribe_registro.py --slave 3 --reg 63 --valor 179 --baud 38400

ATENCION: parar Node-RED antes de ejecutar.
"""
import argparse
import serial
import struct
import sys


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def lee_registro(ser, slave, addr):
    pdu = struct.pack(">BBHH", slave, 3, addr, 1)
    ser.reset_input_buffer()
    ser.write(pdu + struct.pack("<H", crc16(pdu)))
    resp = ser.read(7)
    if len(resp) >= 7 and resp[0] == slave and resp[1] == 3:
        return struct.unpack(">H", resp[3:5])[0]
    return None


def escribe_registro(ser, slave, addr, valor):
    """FC=6: write single holding register."""
    pdu = struct.pack(">BBHH", slave, 6, addr, valor)
    ser.reset_input_buffer()
    ser.write(pdu + struct.pack("<H", crc16(pdu)))
    resp = ser.read(8)
    if len(resp) >= 8 and resp[0] == slave and resp[1] == 6:
        # FC=6 echo: [slave][6][addr_hi][addr_lo][val_hi][val_lo][crc_lo][crc_hi]
        ack_addr = struct.unpack(">H", resp[2:4])[0]
        ack_val = struct.unpack(">H", resp[4:6])[0]
        if ack_addr == addr and ack_val == valor:
            return True
    return False


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--slave", type=int, required=True)
    p.add_argument("--reg",   type=int, required=True)
    p.add_argument("--valor", type=int, required=True)
    p.add_argument("--port",  default="/dev/ttyAMA0")
    p.add_argument("--baud",  type=int, default=115200)
    p.add_argument("--timeout", type=float, default=1.0)
    p.add_argument("--no-verify", action="store_true",
                   help="No leer despues para verificar")
    args = p.parse_args()

    ser = serial.Serial(args.port, args.baud, timeout=args.timeout)

    print(f"[*] Slave {args.slave}, registro {args.reg}")

    val_antes = lee_registro(ser, args.slave, args.reg)
    print(f"    Valor ANTES:    {val_antes}")
    print(f"    Valor a escribir: {args.valor}")

    if val_antes == args.valor:
        print("[!] El valor ya es el correcto. No se escribe nada.")
        return

    print(f"[*] Escribiendo FC=6 ...")
    ok = escribe_registro(ser, args.slave, args.reg, args.valor)
    if ok:
        print(f"    Respuesta del slave: ACK")
    else:
        print(f"    [X] No respondio o respuesta invalida")
        sys.exit(1)

    if args.no_verify:
        return

    val_despues = lee_registro(ser, args.slave, args.reg)
    print(f"    Valor DESPUES:  {val_despues}")

    if val_despues == args.valor:
        print(f"[OK] Escritura confirmada.")
    else:
        print(f"[!] El valor leido no coincide con el escrito.")
        print(f"    Posibles causas:")
        print(f"     - Validacion de rango en el firmware rechazo el valor")
        print(f"     - Corrupcion de lectura tras la escritura")
        print(f"     - El registro es de solo lectura")
        sys.exit(2)


if __name__ == "__main__":
    main()
