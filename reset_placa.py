#!/usr/bin/env python3
"""
Reset remoto de placas por Modbus, con las secuencias REALES del firmware
(verificadas en Gesinne/FW, Events.c, v1.4.13).

    python3 reset_placa.py --ver                      # diagnostico, no escribe nada
    python3 reset_placa.py --slave 1 --reset          # reset normal (exige estado 0)
    python3 reset_placa.py --slave 1 --emergencia     # reset incondicional (v1.4.11+)

Secuencias (NO son las que usaba spam_reset.py):
  reset normal  -> reg 110 (FLAG_RST) = 0xCACA  y luego reg 111 = 0xCACA
                   el firmware RECHAZA cualquier otro valor en el 110, y el
                   111 solo actua si ESTADO_ACTUAL == 0 (placa parada).
  emergencia    -> reg 113 = 0xDEAD DOS veces seguidas. Sin llave previa y
                   sin exigir estado 0. Solo en firmware >= 1.4.11.

Por que existe el diagnostico: desde v1.4.11 el firmware arranca Modbus ANTES
de leer la FLASH, con direccion 1 y 115200 por defecto. Una placa que se
cuelgue en la cascada FLASH se queda contestando como SLAVE 1. Si L1 ya es la
1, hay DOS placas respondiendo a la vez: el bus se llena de tramas corruptas,
la fase colgada da 0 mensajes y las otras caen en picado. Eso se ve aqui como
muchos CRC malos en el slave 1 y silencio en el slave de la fase perdida.

ATENCION: parar Node-RED antes (sudo systemctl stop nodered); el puerto debe
estar libre (sudo lsof /dev/ttyAMA0 vacio).
"""
import argparse
import struct
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("falta pyserial: sudo apt install python3-serial")

CACA = 0xCACA   # 51908
DEAD = 0xDEAD   # 57005
FLAG_RST, REG_RESET, REG_EMER = 110, 111, 113
REG_VERSION, REG_ESTADO, REG_ALARMAS = 100, 0, 2
REG_SERIE = 41   # numero de serie de la PCB: identifica QUE placa contesta
FLAG_EST, REG_ESTADO_DES = 30, 31
ABCD = 0xABCD    # 43981: llave del registro de estado
BROADCAST = 0
FASE = {1: "L1", 2: "L2", 3: "L3"}


def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def _tx(ser, pdu):
    ser.reset_input_buffer()
    ser.write(pdu + struct.pack("<H", crc16(pdu)))


def lee(ser, slave, addr):
    """Devuelve (valor, estado) con estado en {'ok','crc','excepcion','silencio'}."""
    _tx(ser, struct.pack(">BBHH", slave, 3, addr, 1))
    resp = ser.read(7)
    if not resp:
        return None, "silencio"
    if len(resp) >= 5 and resp[1] == 0x83:
        return None, "excepcion"
    if len(resp) < 7:
        return None, "crc"
    if crc16(resp[:5]) != struct.unpack("<H", resp[5:7])[0]:
        return None, "crc"
    return struct.unpack(">H", resp[3:5])[0], "ok"


def escribe(ser, slave, addr, valor):
    _tx(ser, struct.pack(">BBHH", slave, 6, addr, valor))
    resp = ser.read(8)
    if not resp:
        return "silencio"
    if len(resp) >= 5 and resp[1] == 0x86:
        return "excepcion %d" % resp[2]
    if len(resp) >= 8 and resp[0] == slave and resp[1] == 6:
        return "ok"
    return "respuesta rara (%s)" % resp.hex()


def diagnostico(ser, slaves, intentos):
    print("  slave  fase  ok   CRC malo  silencio  version  estado  alarmas")
    sospecha = {}
    for s in slaves:
        cuenta = {"ok": 0, "crc": 0, "excepcion": 0, "silencio": 0}
        ver = None
        for _ in range(intentos):
            v, st = lee(ser, s, REG_VERSION)
            cuenta[st] += 1
            if st == "ok":
                ver = v
            time.sleep(0.05)
        # con tasas de respuesta del 1% una sola lectura nunca entra: insistir
        est = ala = None
        for _ in range(intentos):
            if est is None:
                v, st = lee(ser, s, REG_ESTADO)
                if st == "ok":
                    est = v
            if ala is None:
                v, st = lee(ser, s, REG_ALARMAS)
                if st == "ok":
                    ala = v
            if est is not None and ala is not None:
                break
            time.sleep(0.03)
        print("  %5d  %-4s  %-3d  %-8d  %-8d  %-7s  %-6s  %s" % (
            s, FASE.get(s, "?"), cuenta["ok"], cuenta["crc"], cuenta["silencio"],
            ver if ver is not None else "-",
            est if est is not None else "-",
            ("0x%04X" % ala) if ala is not None else "-"))
        if ala:
            bits = ["MS mando saturado", "CC sobrecorriente", "ST sobretemperatura",
                    "SC sobrecarga", "SW bloqueo switch PCB", "RB bloqueo enable externo",
                    "FA alimentacion +24V < 20V", "VI tension de fase < 80Vac",
                    "TT transitorio de Vin", "EI encendido incorrecto", "MR RAM corrupta"]
            activas = [bits[i] for i in range(len(bits)) if ala & (1 << i)]
            if activas:
                print("         alarmas de %s: %s" % (FASE.get(s, s), " | ".join(activas)))
                print("         (desde v1.4.11 NO sube de estado con ninguna alarma activa)")
        sospecha[s] = cuenta
    print()
    colision = [s for s, c in sospecha.items()
                if c["crc"] >= max(2, intentos // 4) and c["ok"] < intentos]
    mudos = [s for s, c in sospecha.items() if c["ok"] == 0]
    if colision:
        print("  *** CRC malos en el slave %s: hay DOS placas contestando a la vez."
              % ", ".join(str(s) for s in colision))
        print("      Una placa colgada en la cascada FLASH se queda en direccion 1.")
        print("      Arreglo:  python3 reset_placa.py --slave %d --emergencia" % colision[0])
        print("      (resetea las dos; vuelven con su direccion real si la FLASH esta sana)")
    if mudos:
        print("  *** sin respuesta en el slave %s (fase %s)."
              % (", ".join(str(s) for s in mudos),
                 ", ".join(FASE.get(s, "?") for s in mudos)))
    if not colision and not mudos:
        print("  las tres placas contestan limpias.")
    return colision, mudos


BAUDS = [38400, 115200, 57600, 19200, 9600]
PROC = "/proc/tty/driver/ttyAMA"


def contadores():
    """Lee tx/rx/fe/brk del driver. Necesita root."""
    try:
        txt = open(PROC).read()
    except PermissionError:
        import subprocess
        try:
            txt = subprocess.run(["sudo", "-n", "cat", PROC], capture_output=True,
                                 text=True, timeout=5).stdout
        except Exception:
            return None
    if not txt.strip():
        return None
    d = {}
    for campo in ("tx", "rx", "fe", "brk", "oe", "pe"):
        for tok in txt.split():
            if tok.startswith(campo + ":"):
                try:
                    d[campo] = int(tok.split(":")[1])
                except ValueError:
                    pass
                break
    return d or None


def medir(puerto, baud, slaves, preguntas):
    """Pregunta N veces y mide cuanto entra por el UART. Diagnostico de bus."""
    antes = contadores()
    if antes is None:
        sys.exit("no se pudieron leer los contadores: ejecuta con sudo")
    print("=== medida con trafico propio: %d preguntas a %d baud ===" % (preguntas, baud))
    print("  antes:  " + "  ".join("%s=%d" % (k, v) for k, v in sorted(antes.items())))
    ser = serial.Serial(puerto, baud, timeout=0.2)
    time.sleep(0.15)
    respuestas = 0
    aciertos = []           # (segundo, slave, valor)
    t0 = time.time()
    try:
        for i in range(preguntas):
            s = slaves[i % len(slaves)]
            v, st = lee(ser, s, REG_VERSION)
            if st == "ok":
                respuestas += 1
                aciertos.append((time.time() - t0, s, v))
    finally:
        ser.close()
    time.sleep(0.3)
    despues = contadores()
    print("  despues:" + "  ".join("%s=%d" % (k, v) for k, v in sorted(despues.items())))
    d = {k: despues.get(k, 0) - antes.get(k, 0) for k in antes}
    print("  DELTA:  " + "  ".join("%s=%+d" % (k, v) for k, v in sorted(d.items())))
    print("  respuestas validas: %d de %d" % (respuestas, preguntas))
    if aciertos:
        print("  QUIEN y CUANDO contesto:")
        prev = None
        for seg, sl, val in aciertos:
            hueco = "" if prev is None else "   (+%.1f s desde la anterior)" % (seg - prev)
            print("    %6.1f s  %s  version=%s%s" % (seg, FASE.get(sl, sl), val, hueco))
            prev = seg
        if len(aciertos) >= 3:
            hs = [aciertos[i + 1][0] - aciertos[i][0] for i in range(len(aciertos) - 1)]
            reg = max(hs) - min(hs) < max(1.0, sum(hs) / len(hs) * 0.4)
            print("  huecos entre respuestas: " + ", ".join("%.1f" % h for h in hs) + " s")
            if reg:
                print("  *** los huecos son REGULARES: la placa contesta en ventanas")
                print("      periodicas -> bucle de reinicio (watchdog). Cada vez que")
                print("      arranca atiende Modbus un instante y se vuelve a colgar.")
    print()

    tx, rx, fe, brk = d.get("tx", 0), d.get("rx", 0), d.get("fe", 0), d.get("brk", 0)
    if tx == 0:
        print("  *** no se envio nada: el puerto esta ocupado o mal abierto.")
    elif brk > 0:
        print("  *** brk SUBE (%+d): alguien MANTIENE el par a nivel bajo." % brk)
        print("      Transceptor enganchado en transmision. Domina el bus y tapa a")
        print("      las demas placas. No se arregla en remoto: hay que desconectar")
        print("      la placa culpable del par PUENTEANDO A-A y B-B (si se deja")
        print("      abierto se parte la cadena).")
    elif rx == 0 and fe == 0:
        print("  *** NO ENTRA NI UN BYTE: no es corrupcion, es ausencia.")
        print("      Transceptor que no oye, par de recepcion abierto, o placas sin")
        print("      alimentacion. Caso del 00152 -> cambiar el HAT.")
    elif fe > 0:
        print("  *** ENTRAN BYTES CORRUPTOS (fe=%+d sobre rx=%+d): problema" % (fe, rx))
        print("      ELECTRICO en el par, no de software ni de velocidad. Mirar")
        print("      terminacion, apantallado, masa comun y placas que ensucien.")
    elif rx > tx * 2:
        print("  *** el bus va bien (rx >> tx y fe=0).")
    elif respuestas and abs(rx - respuestas * 7) <= 2:
        print("  *** las respuestas que llegan son PERFECTAS (rx=%+d = %d tramas de 7" % (rx, respuestas))
        print("      bytes, fe=0): no hay ruido ni corrupcion ni problema de velocidad.")
        print("      El problema es que solo contesta %.1f%% de las veces. Causa tipica:" % (100.0 * respuestas / preguntas))
        print("      placa en BUCLE DE REINICIO (se cuelga en la cascada FLASH y el")
        print("      watchdog la resetea), o alimentacion de control intermitente.")
        print("      Siguiente: medir a 115200 en el slave 1 -- al arrancar, el firmware")
        print("      atiende Modbus con direccion 1 y 115200 antes de leer la FLASH.")
    else:
        print("  *** entran bytes pero pocos (rx=%+d frente a tx=%+d) y sin errores" % (rx, tx))
        print("      de trama: respuestas truncadas o placas que contestan a medias.")


def barrido(puerto, slaves, intentos):
    """Prueba cada velocidad contra cada slave. No escribe nada."""
    print("=== barrido de velocidades en %s ===" % puerto)
    print("  (silencio en TODAS = el bus no habla: alimentacion, par cortado o")
    print("   transceptor; respuestas en una = esa es la velocidad real)\n")
    encontrado = []
    for baud in BAUDS:
        try:
            ser = serial.Serial(puerto, baud, timeout=0.4)
        except Exception as e:
            print("  %6d  no se pudo abrir: %s" % (baud, e))
            continue
        time.sleep(0.15)
        linea = []
        for s in slaves:
            ok = crc = 0
            for _ in range(intentos):
                v, st = lee(ser, s, REG_VERSION)
                if st == "ok":
                    ok += 1
                elif st == "crc":
                    crc += 1
                time.sleep(0.03)
            linea.append("%s:%d ok/%d crc" % (FASE.get(s, s), ok, crc))
            if ok:
                encontrado.append((baud, s, ok))
        print("  %6d   %s" % (baud, "   ".join(linea)))
        ser.close()
    print()
    if encontrado:
        print("  *** CONTESTAN:")
        for baud, s, ok in encontrado:
            print("      %s a %d baud (%d respuestas buenas)" % (FASE.get(s, s), baud, ok))
    else:
        print("  *** silencio en las 5 velocidades y los 3 slaves.")
        print("      No es un problema de velocidad. Siguiente: alimentacion de las")
        print("      placas, continuidad del par A/B, y contadores del UART")
        print("      (sudo cat /proc/tty/driver/ttyAMA dos veces separadas 1 min:")
        print("       si tx sube y rx NO, el transceptor no oye).")
    return encontrado


REGS = [(0, "estado actual"), (2, "alarmas"), (3, "tension salida Vo"),
        (41, "NUMERO DE SERIE PCB"),
        (4, "tension entrada Vin"), (5, "frecuencia red"), (6, "corriente equipo dA"),
        (17, "temperatura interna"), (31, "estado deseado"), (47, "dead-time"),
        (48, "direccion Modbus"), (61, "velocidad"), (100, "version FW"),
        (102, "micro"), (103, "restauracion FLASH")]


def ficha(puerto, baud, slave, intentos):
    """Lee registros clave insistiendo. Varios valores en el mismo registro =
    varias placas respondiendo a la misma direccion."""
    ser = serial.Serial(puerto, baud, timeout=0.4)
    time.sleep(0.15)
    print("=== ficha del slave %d a %d baud (hasta %d intentos por registro) ===" % (slave, baud, intentos))
    print("  reg  que es                      valor(es) distintos        lecturas")
    sospecha_varias = []
    try:
        for reg, nombre in REGS:
            vistos = {}
            for _ in range(intentos):
                v, st = lee(ser, slave, reg)
                if st == "ok":
                    vistos[v] = vistos.get(v, 0) + 1
                    if len(vistos) >= 3 or sum(vistos.values()) >= 4:
                        break
                time.sleep(0.02)
            if not vistos:
                print("  %3d  %-28s  %-25s  %s" % (reg, nombre, "-- sin respuesta --", 0))
                continue
            txt = ", ".join("%d(x%d)" % (v, n) for v, n in sorted(vistos.items()))
            print("  %3d  %-28s  %-25s  %d" % (reg, nombre, txt, sum(vistos.values())))
            # Vin y temperatura fluctuan en la MISMA placa, asi que dos valores
            # parecidos no son dos placas. Solo cuenta una diferencia grande:
            # entre fases Vin difiere en voltios (>1,5%) y la temperatura en grados.
            if reg in (4, 17) and len(vistos) >= 2:
                vs = sorted(vistos)
                disp = (vs[-1] - vs[0]) / float(vs[-1]) if vs[-1] else 0
                umbral = 0.015 if reg == 4 else 0.08
                if disp > umbral:
                    sospecha_varias.append((reg, nombre, len(vistos), disp * 100))
    finally:
        ser.close()
    print()
    if sospecha_varias:
        print("  *** VARIAS PLACAS en la direccion %d: los registros" % slave)
        for reg, nombre, n, disp in sospecha_varias:
            print("      %d (%s): %d valores, dispersion %.1f%%." % (reg, nombre, n, disp))
        print("      Tension de entrada y temperatura NO pueden coincidir entre fases,")
        print("      asi que hay mas de una placa contestando. Pasa cuando la FLASH se")
        print("      restaura y todas vuelven a la direccion de fabrica.")
        print("      Arreglo: hay que separarlas fisicamente para reasignar direcciones")
        print("      (reg 48), no se puede direccionar una sola si comparten direccion.")
    else:
        print("  una sola placa contesta en esta direccion (las variaciones pequenas")
        print("  de Vin y temperatura son fluctuacion normal de la medida).")
    print("  (reg 103 distinto de 0 = hubo RESTAURACION DE FLASH: la placa perdio su")
    print("   configuracion y arranca en estado 0, por eso no regula aunque este sana)")


PAUSAS = [0, 0.01, 0.02, 0.05, 0.1, 0.2, 0.3]


def ritmo(puerto, baud, slave, por_pausa):
    """La misma pregunta a distintos ritmos. Si la tasa sube al frenar, el
    problema es el RITMO de interrogacion y se arregla en el flow, sin visita."""
    print("=== tasa de respuesta frente al ritmo (slave %d, %d baud) ===" % (slave, baud))
    print("  pausa entre preguntas    respuestas    tasa")
    res = []
    ser = serial.Serial(puerto, baud, timeout=0.4)
    time.sleep(0.15)
    try:
        for pausa in PAUSAS:
            ok = 0
            for _ in range(por_pausa):
                _, st = lee(ser, slave, REG_VERSION)
                if st == "ok":
                    ok += 1
                if pausa:
                    time.sleep(pausa)
            tasa = 100.0 * ok / por_pausa
            barra = "#" * int(tasa / 4)
            print("  %6.0f ms                 %3d/%-3d       %5.1f%%  %s"
                  % (pausa * 1000, ok, por_pausa, tasa, barra))
            res.append((pausa, tasa))
    finally:
        ser.close()
    print()
    sin, con = res[0][1], max(t for _, t in res)
    mejor = [p for p, t in res if t == con][0]
    if con >= 80 and con > sin + 20:
        print("  *** SE ARREGLA EN REMOTO. Con %.0f ms de pausa responde el %.0f%%," % (mejor * 1000, con))
        print("      frente al %.0f%% sin pausa. Las placas estan bien: lo que falla es" % sin)
        print("      que se les pregunta mas rapido de lo que pueden contestar.")
        print("      Bajar el ritmo del flow (fix_modbus_resiliente.py --ritmo) y")
        print("      subir el intervalo de sondeo.")
    elif con > sin + 20:
        print("  *** mejora al frenar (%.0f%% -> %.0f%%) pero sigue lejos del 100%%:" % (sin, con))
        print("      bajar el ritmo ayudara, pero hay algo mas (senal debil en el par,")
        print("      receptor del HAT degradado).")
    else:
        print("  *** el ritmo NO es el problema (%.0f%% -> %.0f%%): no se arregla" % (sin, con))
        print("      frenando el flow. Apunta al receptor del HAT o al par.")
    return res


def broadcast_estado(puerto, baud, estado, confirmado):
    """Pide un estado a TODAS las placas por broadcast (slave 0, sin respuesta).

    Para recuperar un equipo cuyas placas NO podemos oir: la orden sale aunque
    no nos contesten. NO toca la FLASH -- el estado deseado se procesa en el
    bucle principal, en RAM -- asi que no puede desparametrizar una placa.
    El firmware NO sube de estado si hay cualquier alarma activa (v1.4.11), asi
    que una placa en mal estado se queda donde esta por si misma.
    """
    nombre = {0: "0 (bypass/apagado)", 1: "1 (apagado)", 2: "2 (regulando)"}[estado]
    if not confirmado:
        print("  Esto escribe en un equipo EN CARGA y en casa de un cliente.")
        print("  Pide a todas las placas el estado %s." % nombre)
        print("  Si es lo que quieres, repite el comando anadiendo  --si")
        return
    ser = serial.Serial(puerto, baud, timeout=0.3)
    time.sleep(0.15)
    try:
        print("=== BROADCAST a %d baud: estado %s ===" % (baud, nombre))
        # llave y accion en la MISMA sesion de puerto: la llave caduca
        for reg, val, que in ((FLAG_EST, ABCD, "llave del estado"),
                              (REG_ESTADO_DES, estado, "estado deseado")):
            _tx(ser, struct.pack(">BBHH", BROADCAST, 6, reg, val))
            print("   reg %-3d = 0x%04X  (%s) enviado" % (reg, val, que))
            time.sleep(0.15)   # el broadcast no responde: solo se deja hueco
        print("\n  enviado. El broadcast no contesta, asi que la confirmacion es")
        print("  INDIRECTA: leer la placa que si habla y mirar si cambio.")
        time.sleep(3)
        print("\n=== comprobacion en la placa que contesta ===")
        for reg, nombre_reg in ((REG_ESTADO, "estado actual"), (3, "tension salida Vo"),
                                (4, "tension entrada Vin"), (17, "temperatura")):
            val = None
            for _ in range(120):
                v, st = lee(ser, 1, reg)
                if st == "ok":
                    val = v
                    break
                time.sleep(0.02)
            print("   %-20s %s" % (nombre_reg, val if val is not None else "no se pudo leer"))
        print("\n  Si el estado actual es 2 y Vo se separa de Vin, el equipo REGULA.")
        print("  Si Vo sigue pegada a Vin, sigue en bypass.")
    finally:
        ser.close()


def quien(puerto, baud, dirs, intentos):
    """Barre direcciones leyendo el REGISTRO 41 (numero de serie de la PCB).
    A diferencia de Vin o la temperatura, el numero de serie es FIJO y DISTINTO
    en cada placa: si una direccion devuelve varios, hay varias placas ahi."""
    print("=== que placa hay en cada direccion (reg 41 = nº de serie) ===")
    print("  %d intentos por direccion a %d baud; con tasas del 1%% hacen falta" % (intentos, baud))
    print("  muchos (un barrido de 1 intento por direccion es ciego)\n")
    print("  dir   series que contestan            lecturas")
    hallado = {}
    ser = serial.Serial(puerto, baud, timeout=0.3)
    time.sleep(0.15)
    try:
        for d in dirs:
            vistos = {}
            for _ in range(intentos):
                v, st = lee(ser, d, REG_SERIE)
                if st == "ok":
                    vistos[v] = vistos.get(v, 0) + 1
                time.sleep(0.01)
            if vistos:
                txt = ", ".join("%d(x%d)" % (v, n) for v, n in sorted(vistos.items()))
                print("  %3d   %-32s %d" % (d, txt, sum(vistos.values())))
                hallado[d] = vistos
            else:
                print("  %3d   %-32s %d" % (d, "-- silencio --", 0))
    finally:
        ser.close()
    print()
    if not hallado:
        print("  *** ninguna placa contesta en ninguna direccion. El fallo esta en el")
        print("      punto comun (HAT o par), no en las direcciones.")
        return hallado
    for d, vistos in hallado.items():
        if len(vistos) > 1:
            print("  *** DIRECCION %d COMPARTIDA por las placas %s."
                  % (d, " y ".join(str(v) for v in sorted(vistos))))
            print("      Modbus no permite hablar con una sola de ellas, asi que")
            print("      reasignar direcciones EXIGE separarlas fisicamente.")
            print("      LO QUE SI SE PUEDE EN REMOTO: ponerlas todas a regular por")
            print("      BROADCAST (slave 0, sin respuesta): el equipo recupera servicio")
            print("      aunque la telemetria por fase siga sin poder separarse.")
    unicas = {d: list(v)[0] for d, v in hallado.items() if len(v) == 1}
    if unicas:
        print("  placas identificadas:")
        for d, serie in sorted(unicas.items()):
            print("      direccion %d -> PCB nº %d" % (d, serie))
        if len(unicas) < 3:
            print("  faltan placas: o estan en una direccion no barrida (ampliar --dirs)")
            print("  o no contestan. Con el reg 41 ya no hay dudas de QUIEN es cada una.")
    return hallado


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--puerto", default="/dev/ttyAMA0")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--slave", type=int)
    p.add_argument("--slaves", default="1,2,3", help="para --ver")
    p.add_argument("--intentos", type=int, default=8)
    p.add_argument("--ver", action="store_true", help="solo diagnostico")
    p.add_argument("--regular", action="store_true",
                   help="BROADCAST: pide a TODAS las placas estado 2 (regulando)")
    p.add_argument("--bypass", action="store_true",
                   help="BROADCAST: pide a TODAS las placas estado 0 (bypass)")
    p.add_argument("--si", action="store_true",
                   help="confirma una escritura por broadcast en un equipo en carga")
    p.add_argument("--quien", action="store_true",
                   help="barre direcciones leyendo el num de serie (reg 41): dice QUE\nplaca esta en cada direccion, insistiendo lo necesario")
    p.add_argument("--dirs", default="1,2,3,4,5,6,7,8,9,10")
    p.add_argument("--ritmo", action="store_true",
                   help="mide la tasa de respuesta con pausas crecientes")
    p.add_argument("--ficha", action="store_true",
                   help="lee una bateria de registros insistiendo, y detecta si hay\nvarias placas contestando en la misma direccion")
    p.add_argument("--medir", action="store_true",
                   help="genera trafico y mide el delta de los contadores del UART")
    p.add_argument("--barrer", action="store_true",
                   help="prueba todas las velocidades x slaves (no escribe nada)")
    p.add_argument("--reset", action="store_true", help="110=0xCACA + 111=0xCACA")
    p.add_argument("--emergencia", action="store_true", help="113=0xDEAD x2")
    a = p.parse_args()

    if not (a.ver or a.reset or a.emergencia or a.barrer or a.medir or a.ficha
            or a.ritmo or a.quien or a.regular or a.bypass):
        a.ver = True

    if a.regular or a.bypass:
        broadcast_estado(a.puerto, a.baud, 2 if a.regular else 0, a.si)
        return

    if a.quien:
        quien(a.puerto, a.baud, [int(x) for x in a.dirs.split(",")], max(60, a.intentos))
        return

    if a.ritmo:
        ritmo(a.puerto, a.baud, a.slave or 1, max(20, a.intentos))
        return

    if a.ficha:
        ficha(a.puerto, a.baud, a.slave or 1, max(40, a.intentos))
        return

    if a.medir:
        medir(a.puerto, a.baud, [int(x) for x in a.slaves.split(",")],
              max(50, a.intentos))
        return

    if a.barrer:
        barrido(a.puerto, [int(x) for x in a.slaves.split(",")], max(3, a.intentos // 2))
        return

    ser = serial.Serial(a.puerto, a.baud, timeout=0.4)
    time.sleep(0.2)
    try:
        if a.ver:
            print("=== diagnostico en %s @ %d ===" % (a.puerto, a.baud))
            diagnostico(ser, [int(x) for x in a.slaves.split(",")], a.intentos)
            return

        if not a.slave:
            sys.exit("indica --slave")

        est, st = lee(ser, a.slave, REG_ESTADO)
        print("  estado actual del slave %d: %s" % (a.slave, est if st == "ok" else st))

        if a.emergencia:
            print("  EMERGENCY RESET: reg %d = 0x%04X, dos veces" % (REG_EMER, DEAD))
            print("   1a escritura (arma): %s" % escribe(ser, a.slave, REG_EMER, DEAD))
            time.sleep(0.1)
            print("   2a escritura (resetea): %s" % escribe(ser, a.slave, REG_EMER, DEAD))
            print("  (la placa no contesta mientras arranca; es normal)")
        else:
            if est not in (0, None) and st == "ok":
                print("  AVISO: el estado es %d, no 0. El firmware RECHAZARA el reset" % est)
                print("  del 111. Para una placa en marcha usa --emergencia.")
            print("  arma el reset: reg %d = 0x%04X -> %s"
                  % (FLAG_RST, CACA, escribe(ser, a.slave, FLAG_RST, CACA)))
            time.sleep(0.1)
            print("  ejecuta:       reg %d = 0x%04X -> %s"
                  % (REG_RESET, CACA, escribe(ser, a.slave, REG_RESET, CACA)))

        print("\n  esperando 6 s a que arranque...")
        time.sleep(6)
        print("=== despues del reset ===")
        diagnostico(ser, [1, 2, 3], 6)
    finally:
        ser.close()


if __name__ == "__main__":
    main()
