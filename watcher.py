#!/usr/bin/env python3
"""
Watcher daemon: vigila el bus continuamente buscando slaves 2 y 3.
- Cada X segundos hace un poll suave a slaves 2 y 3
- Cada Y minutos envia un broadcast reset
- Loguea cualquier respuesta inesperada
- Si en algun momento aparecen slaves 2 o 3, escribe alerta

NO tiene que parar Node-RED si se ejecuta en momentos donde
Node-RED no esta saturando el bus (entre comandos). Pero
para uso intensivo, mejor parar NR.

Uso:
    # Ejecucion simple en foreground (Ctrl+C para parar):
    python3 watcher.py

    # En background para que siga al cerrar sesion:
    nohup python3 watcher.py > /tmp/watcher.log 2>&1 &

    # Ver el log en vivo:
    tail -f /tmp/watcher.log
"""
import argparse
import serial
import struct
import time
import sys
from datetime import datetime


def crc16(d):
    crc = 0xFFFF
    for b in d:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def ts():
    return datetime.now().strftime('%Y-%m-%d %H:%M:%S')


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", default="/dev/ttyAMA0")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--poll-secs", type=float, default=10,
                   help="Cada cuanto poll a slaves 2 y 3 (s)")
    p.add_argument("--reset-mins", type=float, default=5,
                   help="Cada cuanto broadcast reset (min)")
    p.add_argument("--out", default="/tmp/watcher.log")
    args = p.parse_args()

    s = serial.Serial(args.port, args.baud, timeout=1.0)

    # Frames pre-armados:
    read_s2 = struct.pack('>BBHH', 2, 3, 0, 1)
    read_s2 += struct.pack('<H', crc16(read_s2))
    read_s3 = struct.pack('>BBHH', 3, 3, 0, 1)
    read_s3 += struct.pack('<H', crc16(read_s3))
    reset_bcast = struct.pack('>BBHH', 0, 6, 110, 1)
    reset_bcast += struct.pack('<H', crc16(reset_bcast))

    print(f"[{ts()}] WATCHER iniciado. Polling cada {args.poll_secs}s,"
          f" reset cada {args.reset_mins}min", flush=True)

    last_reset = 0
    poll_count = 0
    last_status_print = time.time()

    while True:
        try:
            # 1) Poll slave 2:
            s.reset_input_buffer()
            s.write(read_s2)
            time.sleep(0.5)
            resp2 = s.read(50)

            # 2) Poll slave 3:
            s.reset_input_buffer()
            s.write(read_s3)
            time.sleep(0.5)
            resp3 = s.read(50)

            poll_count += 1

            # Check respuestas validas:
            if len(resp2) >= 7 and resp2[0] == 2 and resp2[1] == 3:
                val = struct.unpack('>H', resp2[3:5])[0]
                print(f"[{ts()}] !!! SLAVE 2 DESPIERTA !!! reg 0 = {val}",
                      flush=True)
                print(f"  Bytes: {resp2.hex()}", flush=True)
            elif len(resp2) > 0:
                print(f"[{ts()}] Slave 2: {len(resp2)} bytes garbled:"
                      f" {resp2.hex()[:60]}", flush=True)

            if len(resp3) >= 7 and resp3[0] == 3 and resp3[1] == 3:
                val = struct.unpack('>H', resp3[3:5])[0]
                print(f"[{ts()}] !!! SLAVE 3 DESPIERTA !!! reg 0 = {val}",
                      flush=True)
                print(f"  Bytes: {resp3.hex()}", flush=True)
            elif len(resp3) > 0:
                print(f"[{ts()}] Slave 3: {len(resp3)} bytes garbled:"
                      f" {resp3.hex()[:60]}", flush=True)

            # 3) Periodic broadcast reset:
            if time.time() - last_reset > args.reset_mins * 60:
                print(f"[{ts()}] Enviando broadcast reset...", flush=True)
                s.write(reset_bcast)
                time.sleep(0.1)
                last_reset = time.time()

            # 4) Status periodico cada 10 minutos:
            if time.time() - last_status_print > 600:
                print(f"[{ts()}] Vivo. {poll_count} polls hechos."
                      f" Sin respuesta valida aun de slaves 2/3.",
                      flush=True)
                last_status_print = time.time()

            time.sleep(args.poll_secs)

        except KeyboardInterrupt:
            print(f"\n[{ts()}] Watcher detenido por usuario.", flush=True)
            s.close()
            sys.exit(0)
        except Exception as e:
            print(f"[{ts()}] Error: {e}", flush=True)
            time.sleep(5)


if __name__ == "__main__":
    main()
