#!/usr/bin/env python3
"""
Escaner Modbus: busca PCBs que no respondan a su slave-ID o baud habitual.

Escenarios que cubre:
  - Slave ID corrupto en RAM/FLASH (la PCB responde a otro ID)
  - Baud rate corrupto (la PCB responde a otra velocidad)
  - Combinacion de los dos

Uso (parar Node-RED antes):
    sudo systemctl stop nodered
    python3 scan_modbus.py
    sudo systemctl start nodered

Opciones:
    --port /dev/ttyAMA0   Puerto serie
    --ids 1-247           Rango de slave IDs a probar (default: 1-247)
    --bauds 9600,19200,38400,57600,115200   Velocidades a probar
    --reg 0               Registro a leer para detectar (default: 0)
    --timeout 0.1         Timeout por intento
    --quick               Solo prueba 1,2,3 + IDs entre 250-255 + 0
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
    """Devuelve el valor o None."""
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


def parse_ids(s):
    """1-10,15,20-25 -> [1,2,...10,15,20,21,...25]"""
    res = []
    for parte in s.split(","):
        parte = parte.strip()
        if "-" in parte:
            a, b = parte.split("-")
            res.extend(range(int(a), int(b)+1))
        else:
            res.append(int(parte))
    return res


def scan(port, baud, ids, reg, timeout):
    """Escanea ids a esta velocidad, devuelve lista [(slave, valor)]."""
    print(f"  --- Probando a {baud} bps ---", file=sys.stderr)
    encontrados = []
    try:
        ser = serial.Serial(port, baud, timeout=timeout)
    except Exception as e:
        print(f"  [X] No se pudo abrir {port} @ {baud}: {e}", file=sys.stderr)
        return encontrados

    for sl in ids:
        v = lee_registro(ser, sl, reg)
        if v is not None:
            print(f"  [OK] Slave {sl} responde a {baud} bps con reg {reg} = {v}", file=sys.stderr)
            encontrados.append((sl, v))
        time.sleep(0.005)

    ser.close()
    return encontrados


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", default="/dev/ttyAMA0")
    p.add_argument("--ids", default="1-247")
    p.add_argument("--bauds", default="115200,38400,19200,57600,9600")
    p.add_argument("--reg", type=int, default=0)
    p.add_argument("--timeout", type=float, default=0.1)
    p.add_argument("--quick", action="store_true",
                   help="Solo IDs 1,2,3,247,248,0 y rango 50-60")
    args = p.parse_args()

    if args.quick:
        ids = [0, 1, 2, 3, 4, 5] + list(range(50, 60)) + [200, 247]
    else:
        ids = parse_ids(args.ids)

    bauds = [int(b.strip()) for b in args.bauds.split(",")]

    print(f"[*] Puerto: {args.port}")
    print(f"[*] Slave IDs a probar: {len(ids)} ({ids[:5]}{'...' if len(ids)>5 else ''})")
    print(f"[*] Baud rates a probar: {bauds}")
    print(f"[*] Registro a leer: {args.reg}")
    print(f"[*] Timeout por intento: {args.timeout}s")
    print()

    total_encontrados = []
    for baud in bauds:
        encontrados = scan(args.port, baud, ids, args.reg, args.timeout)
        for sl, v in encontrados:
            total_encontrados.append((sl, baud, v))

    print()
    print("=" * 60)
    print("  RESULTADO DEL ESCANEO")
    print("=" * 60)
    if total_encontrados:
        print(f"  Slaves encontrados: {len(total_encontrados)}")
        print()
        print(f"  {'Slave':<6} {'Baud':<8} {'Reg ' + str(args.reg):<10}")
        print("  " + "-" * 30)
        for sl, baud, v in total_encontrados:
            print(f"  {sl:<6} {baud:<8} {v:<10}")
    else:
        print("  No se encontraron slaves respondiendo en ningun ID/baud.")
        print()
        print("  Posibles causas:")
        print("  - PCB sin alimentacion (revisar fuente +5V de control)")
        print("  - Transceptor RS-485 de la PCB danado")
        print("  - Cable RS-485 cortado entre HAT y PCB")
        print("  - MCU colgado / stuck (probar power cycle del chopper)")
    print("=" * 60)


if __name__ == "__main__":
    main()
