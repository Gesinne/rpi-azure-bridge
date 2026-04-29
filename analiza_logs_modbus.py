#!/usr/bin/env python3
"""
Parser de logs Node-RED para diagnostico Modbus RS-485.

Lee journalctl/syslog y genera estadisticas:
  - timeouts por slave
  - reconexiones del cliente Modbus (fsm broken/reconnect)
  - inject-while-not-ready por slave
  - distribucion por hora del dia (para encontrar eventos periodicos)
  - rachas largas de fallo (>30s)

Uso:
    # Las ultimas 24 h de journal:
    sudo journalctl --since "24 hours ago" | python3 analiza_logs_modbus.py

    # Una ventana concreta:
    sudo journalctl --since "2026-04-29 00:00:00" --until "2026-04-29 06:00:00" \\
        | python3 analiza_logs_modbus.py

    # Desde un fichero ya volcado:
    python3 analiza_logs_modbus.py < /tmp/log24h.txt
"""
import sys
import re
from collections import defaultdict, Counter
from datetime import datetime


RE_TIMEOUT = re.compile(r"\[error\] \[modbus-flex-getter:(\w+)\] Error: Timed out")
RE_INJECT = re.compile(r"\[warn\] \[modbus-flex-getter:(\w+)\] Flex-Getter -> Inject while node is not ready")
RE_FSM = re.compile(r"\[warn\] \[modbus-client:\w+\] Client -> fsm (\w+) state")
RE_TS_SYSLOG = re.compile(r"^(\w{3})\s+(\d+)\s+(\d{2}):(\d{2}):(\d{2})")
RE_TS_NR = re.compile(r"(\d{2}) (\w{3}) (\d{2}):(\d{2}):(\d{2})")

MES_ES = {"Jan":1,"Feb":2,"Mar":3,"Apr":4,"May":5,"Jun":6,
         "Jul":7,"Aug":8,"Sep":9,"Oct":10,"Nov":11,"Dec":12}


def parse_ts(line: str):
    """Devuelve datetime o None."""
    m = RE_TS_SYSLOG.match(line)
    if m:
        mes, dia, h, mi, s = m.groups()
        return datetime(2026, MES_ES.get(mes, 1), int(dia), int(h), int(mi), int(s))
    m = RE_TS_NR.search(line)
    if m:
        dia, mes, h, mi, s = m.groups()
        return datetime(2026, MES_ES.get(mes, 1), int(dia), int(h), int(mi), int(s))
    return None


def main():
    timeouts = Counter()           # slave -> count
    injects = Counter()
    fsm_states = Counter()
    timeouts_por_hora = defaultdict(Counter)  # hora -> slave -> count
    fsm_por_hora = defaultdict(Counter)       # hora -> estado -> count
    eventos = []                   # (ts, slave, tipo)

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
    print(f"\n{'='*70}")
    print(f"  Ventana analizada: {primera}  ->  {ultima}")
    print(f"  Duracion: {duracion:.1f} horas")
    print(f"{'='*70}\n")

    print("--- Timeouts por slave ---")
    if timeouts:
        total = sum(timeouts.values())
        for sl, c in sorted(timeouts.items(), key=lambda x: -x[1]):
            pct = 100.0 * c / total if total else 0
            tasa_h = c / duracion if duracion > 0 else 0
            print(f"  {sl:<12} {c:>5}  ({pct:5.1f}%)  {tasa_h:5.1f}/h")
    else:
        print("  (ninguno)")

    print("\n--- Inject-while-not-ready por slave ---")
    if injects:
        for sl, c in sorted(injects.items(), key=lambda x: -x[1]):
            print(f"  {sl:<12} {c:>6}")
    else:
        print("  (ninguno)")

    print("\n--- Estados FSM cliente Modbus ---")
    if fsm_states:
        for estado, c in sorted(fsm_states.items(), key=lambda x: -x[1]):
            print(f"  {estado:<12} {c:>5}")
    else:
        print("  (ninguno)")

    print("\n--- Timeouts por hora del dia (busca picos periodicos) ---")
    print(f"  {'Hora':<6} {'Tarj1':>6} {'Tarj2':>6} {'Tarj3':>6} {'Otro':>6} {'TOTAL':>7}  Grafica")
    for h in range(24):
        slaves_h = timeouts_por_hora.get(h, {})
        t1 = slaves_h.get("Tarjeta1", 0)
        t2 = slaves_h.get("Tarjeta2", 0)
        t3 = slaves_h.get("Tarjeta3", 0)
        otros = sum(v for k, v in slaves_h.items() if k not in ("Tarjeta1","Tarjeta2","Tarjeta3"))
        total = t1 + t2 + t3 + otros
        bar = "#" * min(50, total // 5)
        print(f"  {h:02d}:00 {t1:>6} {t2:>6} {t3:>6} {otros:>6} {total:>7}  {bar}")

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
            print(f"  #{i}  {ini}  -> {fin}   ({dur:>6.0f}s)  slaves={','.join(sorted(slaves))}")
    else:
        print("  (sin rachas largas)")

    print()


if __name__ == "__main__":
    main()
