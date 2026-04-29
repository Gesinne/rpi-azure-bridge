#!/usr/bin/env python3
"""
Lee estado actual de las 3 placas ChopperAC via Modbus.

Lee los registros clave para diagnostico:
  - 0:   Estado actual del Chopper (0=bypass, 1=off, 2=regulando)
  - 2:   Alarmas (bitfield)
  - 17:  Temperatura interna
  - 20:  Tiempo restante alarma CC/TT/EI
  - 47:  Dead-time
  - 54:  Contador maniobras por CC
  - 59:  Contador maniobras por ST

Lanzar con Node-RED PARADO. Uso:
    python3 lee_estado_placas.py [--port /dev/ttyAMA0] [--baud 115200]
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


def lee_registro(ser, slave: int, addr: int, intentos: int = 3):
    """Devuelve el valor entero o None si no responde."""
    for _ in range(intentos):
        pdu = struct.pack(">BBHH", slave, 3, addr, 1)
        ser.reset_input_buffer()
        ser.write(pdu + struct.pack("<H", crc16(pdu)))
        resp = ser.read(7)
        if len(resp) >= 7 and resp[0] == slave and resp[1] == 3:
            payload = resp[:-2]
            crc_rx = struct.unpack("<H", resp[-2:])[0]
            if crc16(payload) == crc_rx:
                return struct.unpack(">H", resp[3:5])[0]
        time.sleep(0.05)
    return None


REGS = [
    (0,  "Estado",           "0=bypass 1=off 2=regulando"),
    (2,  "Alarmas",          "bitfield"),
    (3,  "V salida (dV)",    "decivoltios"),
    (4,  "V entrada (dV)",   "decivoltios"),
    (17, "Temp interna",     "°C"),
    (20, "T. rest. alarma",  "s"),
    (47, "Dead-time",        "valor PWM (~2047 normal)"),
    (54, "Contador CC",      "n maniobras por sobrecorriente"),
    (59, "Contador ST",      "n maniobras por sobretemperatura"),
]


def fmt(v):
    if v is None:
        return "  --  "
    return f"{v:>6}"


def fmt_alarmas(v):
    if v is None:
        return "(no responde)"
    if v == 0:
        return "(ninguna)"
    bits = []
    for i in range(16):
        if v & (1 << i):
            bits.append(f"bit{i}")
    return ",".join(bits) + f"  [0x{v:04X}]"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", default="/dev/ttyAMA0")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--slaves", default="1,2,3")
    p.add_argument("--timeout", type=float, default=0.3)
    args = p.parse_args()

    slaves = [int(s) for s in args.slaves.split(",")]
    try:
        ser = serial.Serial(args.port, args.baud, timeout=args.timeout)
    except Exception as e:
        print(f"[!] No se pudo abrir {args.port}: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"\n{'='*78}")
    print(f"  Estado actual placas ChopperAC")
    print(f"  Puerto: {args.port}  @ {args.baud} bps    Slaves: {slaves}")
    print(f"{'='*78}\n")

    print(f"  {'Reg':<5} {'Nombre':<22} ", end="")
    for sl in slaves:
        print(f"{'L'+str(sl):>8}", end="")
    print(f"   {'unidad':<30}")
    print("  " + "-" * 76)

    valores = {}
    for addr, nombre, unidad in REGS:
        if addr == 2:
            continue  # alarmas en bloque aparte
        print(f"  {addr:<5} {nombre:<22} ", end="")
        for sl in slaves:
            v = lee_registro(ser, sl, addr)
            valores[(sl, addr)] = v
            print(fmt(v), end="")
        print(f"   {unidad}")

    print()
    print("  Alarmas activas (registro 2):")
    for sl in slaves:
        v = lee_registro(ser, sl, 2)
        valores[(sl, 2)] = v
        print(f"    L{sl}: {fmt_alarmas(v)}")

    print()
    print("  Resumen rapido:")
    for sl in slaves:
        cc = valores.get((sl, 54))
        st = valores.get((sl, 59))
        dt = valores.get((sl, 47))
        est = valores.get((sl, 0))
        alm = valores.get((sl, 2))
        cc_s = f"CC={cc}" if cc is not None else "CC=??"
        st_s = f"ST={st}" if st is not None else "ST=??"
        dt_s = f"DT={dt}" if dt is not None else "DT=??"
        est_map = {0: "BYPASS", 1: "OFF", 2: "REGULA"}
        est_s = est_map.get(est, f"est={est}")
        alm_s = "OK" if alm == 0 else (f"ALM=0x{alm:04X}" if alm is not None else "??")
        print(f"    L{sl}: {est_s:<8} {alm_s:<14} {dt_s:<10} {cc_s:<10} {st_s}")

    print()


if __name__ == "__main__":
    main()
