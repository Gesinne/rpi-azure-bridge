#!/usr/bin/env python3
"""
Parser de logs Node-RED para diagnostico Modbus RS-485.

Lee journalctl/syslog y genera estadisticas:
  - timeouts por slave
  - reconexiones del cliente Modbus (fsm broken/reconnect)
  - inject-while-not-ready por slave
  - distribucion por hora del dia (para encontrar eventos periodicos)
  - rachas largas de fallo (>30s)

Uso basico:
    sudo journalctl --since "24 hours ago" | python3 analiza_logs_modbus.py

Con identificacion de PCBs por numero de serie (mapping manual):
    sudo journalctl --since "24 hours ago" | python3 analiza_logs_modbus.py \\
        --serials "Tarjeta1=151,Tarjeta2=150,Tarjeta3=152"

Con identificacion automatica via Modbus (parar Node-RED antes):
    sudo systemctl stop nodered
    sudo journalctl --since "24 hours ago" | python3 analiza_logs_modbus.py \\
        --autoserials --port /dev/ttyAMA0
    sudo systemctl start nodered
"""
import sys
import re
import argparse
import struct
from collections import defaultdict, Counter
from datetime import datetime


RE_TIMEOUT = re.compile(r"\[error\] \[modbus-flex-getter:(\w+)\] Error: Timed out")
RE_INJECT = re.compile(r"\[warn\] \[modbus-flex-getter:(\w+)\] Flex-Getter -> Inject while node is not ready")
RE_FSM = re.compile(r"\[warn\] \[modbus-client:\w+\] Client -> fsm (\w+) state")
RE_TS_SYSLOG = re.compile(r"^(\w{3})\s+(\d+)\s+(\d{2}):(\d{2}):(\d{2})")
RE_TS_NR = re.compile(r"(\d{2}) (\w{3}) (\d{2}):(\d{2}):(\d{2})")

MES_ES = {"Jan":1,"Feb":2,"Mar":3,"Apr":4,"May":5,"Jun":6,
         "Jul":7,"Aug":8,"Sep":9,"Oct":10,"Nov":11,"Dec":12}

# Mapping convencional Tarjeta -> Slave ID Modbus
TARJETA_A_SLAVE = {"Tarjeta1": 1, "Tarjeta2": 2, "Tarjeta3": 3}


def parse_ts(line: str):
    m = RE_TS_SYSLOG.match(line)
    if m:
        mes, dia, h, mi, s = m.groups()
        return datetime(2026, MES_ES.get(mes, 1), int(dia), int(h), int(mi), int(s))
    m = RE_TS_NR.search(line)
    if m:
        dia, mes, h, mi, s = m.groups()
        return datetime(2026, MES_ES.get(mes, 1), int(dia), int(h), int(mi), int(s))
    return None


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def lee_serial_modbus(port: str, baud: int, slave: int) -> int:
    """Lee registro 41 (Numero de serie) de un slave. None si no responde."""
    try:
        import serial
    except ImportError:
        return None
    try:
        ser = serial.Serial(port, baud, timeout=0.3)
    except Exception:
        return None
    try:
        for _ in range(3):
            pdu = struct.pack(">BBHH", slave, 3, 41, 1)
            ser.reset_input_buffer()
            ser.write(pdu + struct.pack("<H", crc16(pdu)))
            resp = ser.read(7)
            if len(resp) >= 7 and resp[0] == slave and resp[1] == 3:
                payload = resp[:-2]
                crc_rx = struct.unpack("<H", resp[-2:])[0]
                if crc16(payload) == crc_rx:
                    return struct.unpack(">H", resp[3:5])[0]
        return None
    finally:
        ser.close()


def parse_serials_arg(arg: str) -> dict:
    """'Tarjeta1=151,Tarjeta2=150,Tarjeta3=152' -> {'Tarjeta1':'151',...}"""
    res = {}
    if not arg:
        return res
    for parte in arg.split(","):
        if "=" in parte:
            k, v = parte.split("=", 1)
            res[k.strip()] = v.strip()
    return res


def autoserials(port: str, baud: int) -> dict:
    """Lee S/N de los 3 slaves via Modbus."""
    res = {}
    for tarjeta, slave in TARJETA_A_SLAVE.items():
        sn = lee_serial_modbus(port, baud, slave)
        if sn is not None:
            res[tarjeta] = str(sn)
        else:
            res[tarjeta] = "??"
    return res


def label(tarjeta: str, serials: dict) -> str:
    """'Tarjeta1' -> 'Tarjeta1 (PCB 151)' si tenemos S/N."""
    sn = serials.get(tarjeta)
    if sn:
        return f"{tarjeta} (PCB {sn})"
    return tarjeta


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--serials", default="",
                   help="Mapping manual: 'Tarjeta1=151,Tarjeta2=150,Tarjeta3=152'")
    p.add_argument("--autoserials", action="store_true",
                   help="Leer S/N por Modbus (parar Node-RED antes)")
    p.add_argument("--port", default="/dev/ttyAMA0", help="Puerto serial para autoserials")
    p.add_argument("--baud", type=int, default=115200, help="Baudrate para autoserials")
    args = p.parse_args()

    serials = parse_serials_arg(args.serials)
    if args.autoserials:
        print("[*] Leyendo numeros de serie por Modbus...", file=sys.stderr)
        auto = autoserials(args.port, args.baud)
        print(f"[*] S/N detectados: {auto}", file=sys.stderr)
        for k, v in auto.items():
            if k not in serials:
                serials[k] = v

    timeouts = Counter()
    injects = Counter()
    fsm_states = Counter()
    timeouts_por_hora = defaultdict(Counter)
    fsm_por_hora = defaultdict(Counter)
    eventos = []

    primera = None
    ultima = None

    for line in sys.stdin:
        ts = parse_ts(line)
        if ts:
            if primera is None:
                primera = ts
            ultima = ts

        m = RE_TIMEOUT.search(line)
        if m:
            slave = m.group(1)
            timeouts[slave] += 1
            if ts:
                timeouts_por_hora[ts.hour][slave] += 1
                eventos.append((ts, slave, "timeout"))
            continue

        m = RE_INJECT.search(line)
        if m:
            slave = m.group(1)
            injects[slave] += 1
            continue

        m = RE_FSM.search(line)
        if m:
            estado = m.group(1)
            fsm_states[estado] += 1
            if ts:
                fsm_por_hora[ts.hour][estado] += 1

    if primera is None:
        print("[!] No se reconocio ninguna marca temporal. Revisa la entrada.")
        sys.exit(1)

    duracion = (ultima - primera).total_seconds() / 3600.0
    print(f"\n{'='*78}")
    print(f"  Ventana analizada: {primera}  ->  {ultima}")
    print(f"  Duracion: {duracion:.1f} horas")
    if serials:
        print(f"  Mapping PCB:  " + ", ".join(f"{k}=PCB{v}" for k, v in sorted(serials.items())))
    print(f"{'='*78}\n")

    print("--- Timeouts por slave ---")
    if timeouts:
        total = sum(timeouts.values())
        for sl, c in sorted(timeouts.items(), key=lambda x: -x[1]):
            pct = 100.0 * c / total if total else 0
            tasa_h = c / duracion if duracion > 0 else 0
            print(f"  {label(sl, serials):<24} {c:>5}  ({pct:5.1f}%)  {tasa_h:5.1f}/h")
    else:
        print("  (ninguno)")

    print("\n--- Inject-while-not-ready por slave ---")
    if injects:
        for sl, c in sorted(injects.items(), key=lambda x: -x[1]):
            print(f"  {label(sl, serials):<24} {c:>6}")
    else:
        print("  (ninguno)")

    print("\n--- Estados FSM cliente Modbus ---")
    if fsm_states:
        for estado, c in sorted(fsm_states.items(), key=lambda x: -x[1]):
            print(f"  {estado:<12} {c:>5}")
    else:
        print("  (ninguno)")

    print("\n--- Timeouts por hora del dia (busca picos periodicos) ---")
    h1 = label("Tarjeta1", serials)
    h2 = label("Tarjeta2", serials)
    h3 = label("Tarjeta3", serials)
    print(f"  {'Hora':<6} {h1:>16} {h2:>16} {h3:>16} {'Otro':>6} {'TOTAL':>7}  Grafica")
    for h in range(24):
        slaves_h = timeouts_por_hora.get(h, {})
        t1 = slaves_h.get("Tarjeta1", 0)
        t2 = slaves_h.get("Tarjeta2", 0)
        t3 = slaves_h.get("Tarjeta3", 0)
        otros = sum(v for k, v in slaves_h.items() if k not in ("Tarjeta1","Tarjeta2","Tarjeta3"))
        total = t1 + t2 + t3 + otros
        bar = "#" * min(50, total // 5)
        print(f"  {h:02d}:00 {t1:>16} {t2:>16} {t3:>16} {otros:>6} {total:>7}  {bar}")

    print("\n--- Rachas (>30s sin recuperar) ---")
    eventos.sort()
    rachas = []
    if eventos:
        ini = eventos[0][0]
        ultimo = eventos[0][0]
        slave_set = {eventos[0][1]}
        for ts, sl, _ in eventos[1:]:
            if (ts - ultimo).total_seconds() <= 30:
                ultimo = ts
                slave_set.add(sl)
            else:
                if (ultimo - ini).total_seconds() >= 30:
                    rachas.append((ini, ultimo, slave_set))
                ini = ts
                ultimo = ts
                slave_set = {sl}
        if (ultimo - ini).total_seconds() >= 30:
            rachas.append((ini, ultimo, slave_set))
    if rachas:
        for i, (ini, fin, slaves) in enumerate(rachas, 1):
            dur = (fin - ini).total_seconds()
            slaves_str = ",".join(label(s, serials) for s in sorted(slaves))
            print(f"  #{i}  {ini}  -> {fin}   ({dur:>6.0f}s)  {slaves_str}")
    else:
        print("  (sin rachas largas)")

    print()


if __name__ == "__main__":
    main()
