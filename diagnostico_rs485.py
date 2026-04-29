#!/usr/bin/env python3
"""
Diagnostico RS-485 / Modbus RTU para ChopperAC.

Hace N lecturas a cada slave (1, 2, 3) del registro 47 (dead-time)
y reporta:
  - tasa de exito
  - tiempo medio de respuesta
  - desviacion (jitter)
  - errores por tipo (timeout, CRC, frame incompleto)

Uso:
    python3 diagnostico_rs485.py [--port /dev/ttyUSB0] [--baud 115200]
                                  [--ciclos 1000] [--slaves 1,2,3]
"""
import argparse
import serial
import struct
import time
import statistics
from collections import defaultdict


def crc16_modbus(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return crc


def build_read_holding(slave: int, addr: int, qty: int) -> bytes:
    pdu = struct.pack(">BBHH", slave, 3, addr, qty)
    crc = crc16_modbus(pdu)
    return pdu + struct.pack("<H", crc)


def parse_response(resp: bytes, slave: int):
    """Devuelve (ok, motivo, valor)."""
    if len(resp) < 5:
        return False, "frame_corto", None
    if resp[0] != slave:
        return False, "slave_id_mal", None
    if resp[1] & 0x80:
        return False, f"excepcion_modbus_{resp[2]}", None
    if resp[1] != 3:
        return False, f"fc_inesperada_{resp[1]}", None
    nbytes = resp[2]
    if len(resp) != 3 + nbytes + 2:
        return False, "longitud_mal", None
    payload = resp[:-2]
    crc_rx = struct.unpack("<H", resp[-2:])[0]
    if crc16_modbus(payload) != crc_rx:
        return False, "crc_mal", None
    val = struct.unpack(">H", resp[3:5])[0]
    return True, "ok", val


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", default="/dev/ttyUSB0")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--ciclos", type=int, default=1000)
    p.add_argument("--slaves", default="1,2,3")
    p.add_argument("--addr", type=int, default=47, help="registro a leer")
    p.add_argument("--timeout", type=float, default=0.2)
    args = p.parse_args()

    slaves = [int(s) for s in args.slaves.split(",")]
    ser = serial.Serial(args.port, args.baud, timeout=args.timeout)

    stats = {s: {"ok": 0, "errores": defaultdict(int), "tiempos": []} for s in slaves}

    print(f"[*] Puerto {args.port} @ {args.baud} baud, {args.ciclos} ciclos a slaves {slaves}, registro {args.addr}")
    t0 = time.time()
    for ciclo in range(args.ciclos):
        for sl in slaves:
            req = build_read_holding(sl, args.addr, 1)
            ser.reset_input_buffer()
            t_send = time.perf_counter()
            ser.write(req)
            resp = ser.read(7)  # respuesta esperada: 1+1+1+2+2 = 7 bytes
            t_recv = time.perf_counter()
            ok, motivo, val = parse_response(resp, sl)
            dt = (t_recv - t_send) * 1000  # ms
            if ok:
                stats[sl]["ok"] += 1
                stats[sl]["tiempos"].append(dt)
            else:
                stats[sl]["errores"][motivo] += 1
            time.sleep(0.005)  # 5 ms entre frames, suficiente silencio

        if (ciclo + 1) % 100 == 0:
            print(f"  ciclo {ciclo+1}/{args.ciclos}")

    elapsed = time.time() - t0
    print(f"\n[*] Completado en {elapsed:.1f}s\n")
    print(f"{'Slave':<6} {'OK':>6} {'%':>6} {'t_ms':>10} {'jit':>6}  Errores")
    print("-" * 70)
    for sl in slaves:
        s = stats[sl]
        total = args.ciclos
        pct = 100.0 * s["ok"] / total
        if s["tiempos"]:
            tmed = statistics.mean(s["tiempos"])
            jit = statistics.stdev(s["tiempos"]) if len(s["tiempos"]) > 1 else 0
            t_str = f"{tmed:.1f}"
            jit_str = f"{jit:.1f}"
        else:
            t_str = "-"
            jit_str = "-"
        err_str = ", ".join(f"{k}={v}" for k, v in sorted(s["errores"].items())) or "-"
        print(f"{sl:<6} {s['ok']:>6} {pct:>5.1f} {t_str:>10} {jit_str:>6}  {err_str}")


if __name__ == "__main__":
    main()
