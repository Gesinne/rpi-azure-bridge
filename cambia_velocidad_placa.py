#!/usr/bin/env python3
"""
Cambia la velocidad Modbus (registro 61) de UNA placa.

POR QUE HACE FALTA
`escribe_registro.py` no sirve para el reg 61: la placa RECHAZA esa escritura si
no esta en bypass, y las dos llaves de desbloqueo (reg 30 = 43981, reg 40 = 47818)
CADUCAN al cerrar el puerto, asi que con comandos separados no funciona — tiene
que ir todo en la misma sesion. Y `firmware.sh` lo hace bien pero cambia las TRES
a la vez, de forma sincronizada, que es lo correcto en condiciones normales.
Esto es para el caso de diagnostico: probar una placa sola a otra velocidad.

OJO, LO IMPORTANTE
Si dejas una placa a 38400 y las otras a 115200, el flow de Node-RED solo puede
hablar a UNA velocidad: leera la que coincida y perdera las demas. Para que el
flow lea a la nueva velocidad hay que cambiarselo tambien (lo hace firmware.sh con
actualizar_baudrate_nodered). Como prueba puntual vale; como estado final, no.

Codigos del registro 61:  0 = 115200   1 = 57600   2 = 38400
Registro 31 (estado):     0 = BYPASS   2 = REGULACION

SI HAY VARIAS PLACAS A VELOCIDADES DISTINTAS, no uses esto: firmware.sh tiene
"Rescatar bus Modbus", que habla a CADA placa a su velocidad actual y las iguala
todas a una comun. Esto es para mirar o mover UNA sola.

Uso:
    sudo systemctl stop nodered          # SIEMPRE: el flow ocupa el puerto
    python3 cambia_velocidad_placa.py --slave 1 --ver
    python3 cambia_velocidad_placa.py --slave 1 --vel 38400
    python3 cambia_velocidad_placa.py --slave 1 --vel 115200 --baud 38400   # volver
    sudo systemctl start nodered
"""
import argparse, sys, time

LLAVE_30, LLAVE_40 = 43981, 47818        # 0xABCD y 0xBACA
COD = {115200: 0, 57600: 1, 38400: 2}
BAUD = {v: k for k, v in COD.items()}
REG_ESTADO, REG_VEL = 31, 61

try:
    from pymodbus.client import ModbusSerialClient
except ImportError:
    print("[X] falta pymodbus"); sys.exit(1)


def abrir(port, baud):
    c = ModbusSerialClient(port=port, baudrate=baud, bytesize=8, parity='N',
                           stopbits=1, timeout=0.5)
    return c if c.connect() else None


def leer(c, slave, reg, intentos=5):
    """Con reintentos: en un bus degradado la primera no suele entrar."""
    for _ in range(intentos):
        try:
            r = c.read_holding_registers(address=reg, count=1, slave=slave)
            if not r.isError():
                return r.registers[0]
        except Exception:
            pass
        time.sleep(0.15)
    return None


def escribir(c, slave, reg, valor):
    try:
        return not c.write_register(address=reg, value=valor, slave=slave).isError()
    except Exception:
        return False


def escribir_silencioso(c, slave, reg, valor):
    """Escribe sin mirar la respuesta.

    Las llaves y el reg 61 contestan con excepcion ("Exception response 134")
    aunque la escritura SI se aplique — la placa responde ya con otra velocidad, o
    simplemente no confirma. firmware.sh hace lo mismo con write_silencioso(): si
    se comprueba el retorno, se aborta un cambio que en realidad habria entrado.
    """
    try:
        c.write_register(address=reg, value=valor, slave=slave)
    except Exception:
        pass


def llaves(c, slave):
    """Las dos llaves de desbloqueo, en esta misma sesion y en este orden."""
    escribir_silencioso(c, slave, 30, LLAVE_30)   # habilitar tarjeta
    time.sleep(0.15)
    escribir_silencioso(c, slave, 40, LLAVE_40)   # habilitar config
    time.sleep(0.15)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--slave', type=int, help='1, 2 o 3 (no hace falta con --buscar)')
    p.add_argument('--vel', type=int, choices=sorted(COD), help='velocidad nueva')
    p.add_argument('--baud', type=int, default=115200, help='velocidad ACTUAL de la placa')
    p.add_argument('--port', default='/dev/ttyAMA0')
    p.add_argument('--ver', action='store_true', help='solo mirar, no escribe nada')
    p.add_argument('--buscar', action='store_true',
                   help='prueba las 3 velocidades y dice donde responde cada placa')
    p.add_argument('--si', action='store_true', help='no preguntar')
    a = p.parse_args()

    # Mapa del bus: tras un cambio a medias, cada placa puede estar a una velocidad
    # distinta, y hasta saber donde esta cada una no se puede mover ninguna.
    if a.buscar:
        slaves = [a.slave] if a.slave else [1, 2, 3]
        print(f"  Buscando L{slaves} en 115200 / 57600 / 38400 ...\n")
        encontradas = {}
        for b in (115200, 57600, 38400):
            c = abrir(a.port, b)
            if not c:
                print(f"  [X] no se pudo abrir el puerto a {b}"); continue
            for s_ in slaves:
                if s_ in encontradas:
                    continue
                v = leer(c, s_, REG_VEL, intentos=4)
                if v is None:
                    continue
                e = leer(c, s_, REG_ESTADO, intentos=3)
                est_txt = 'BYPASS' if e == 0 else 'REGULACION' if e == 2 else f'reg31={e}'
                encontradas[s_] = (b, v, e)
                print(f"  L{s_}: responde a {b} baud  |  reg61={v} ({BAUD.get(v, '?')})  |  {est_txt}")
            c.close()
        mudas = [s_ for s_ in slaves if s_ not in encontradas]
        if mudas:
            print(f"\n  L{mudas} no contesta a ninguna de las tres velocidades.")
            print("  Eso ya no es velocidad: mira el par, la alimentacion o la placa.")
        if len(set(v[0] for v in encontradas.values())) > 1:
            print("\n  [!] Hay placas a velocidades DISTINTAS: el flow solo puede hablar a una.")
            print("      Igualalas todas a la del flow (115200), una a una:")
            for s_, (b, _, _) in sorted(encontradas.items()):
                if b != 115200:
                    print(f"        python3 {p} --slave {s_} --vel 115200 --baud {b}")
        return

    if not a.slave:
        print("[X] hace falta --slave (o usa --buscar)"); sys.exit(1)

    c = abrir(a.port, a.baud)
    if not c:
        print(f"[X] no se pudo abrir {a.port} @ {a.baud}"); sys.exit(1)

    vel = leer(c, a.slave, REG_VEL)
    est = leer(c, a.slave, REG_ESTADO)
    print(f"  L{a.slave} @ {a.baud}: reg61 = {vel} ({BAUD.get(vel, '?')} baud) | "
          f"reg31 = {est} ({'BYPASS' if est == 0 else 'REGULACION' if est == 2 else est})")

    if a.ver or a.vel is None:
        c.close(); return

    # Mismo criterio que firmware.sh: sin poder leer el estado no se escribe a ciegas.
    if vel is None or est is None:
        print("[X] no se pueden leer reg61/reg31 — ABORTO sin escribir nada.")
        print("    Sin esa lectura no es seguro tocar la velocidad.")
        c.close(); sys.exit(1)
    if COD[a.vel] == vel:
        print(f"[i] ya esta a {a.vel}. Nada que hacer."); c.close(); return

    if not a.si:
        r = input(f"  ¿Escribo reg61={COD[a.vel]} ({a.vel} baud) en L{a.slave}? [s/N]: ")
        if r.strip().lower() not in ('s', 'si', 'sí'):
            print("  cancelado"); c.close(); return

    # Secuencia magica de firmware.sh: reg31=0 -> reg30 -> reg40 -> reg61.
    # El bypass va PRIMERO: con las llaves puestas antes, la placa rechaza el cambio.
    print("  [1/4] a BYPASS (reg31=0)...")
    if est != 0:
        escribir_silencioso(c, a.slave, REG_ESTADO, 0)
        time.sleep(0.5)
        if leer(c, a.slave, REG_ESTADO) != 0:
            print("[X] no se pudo poner en bypass — ABORTO."); c.close(); sys.exit(1)
    else:
        print("      ya estaba en bypass")

    print("  [2/4] llaves de desbloqueo (reg30, reg40)...")
    llaves(c, a.slave)

    print(f"  [3/4] reg61 = {COD[a.vel]}...")
    escribir_silencioso(c, a.slave, REG_VEL, COD[a.vel])  # contesta ya a la velocidad nueva
    c.close()
    time.sleep(1.0)

    print(f"  [4/4] reconectando a {a.vel} para verificar...")
    c2 = abrir(a.port, a.vel)
    if not c2:
        print(f"[X] no se pudo abrir el puerto a {a.vel}"); sys.exit(1)
    nueva = leer(c2, a.slave, REG_VEL, intentos=8)
    if nueva == COD[a.vel]:
        print(f"  [OK] L{a.slave} responde a {a.vel} baud (reg61={nueva})")
        if est != 0:
            llaves(c2, a.slave)
            escribir_silencioso(c2, a.slave, REG_ESTADO, est)
            time.sleep(0.4)
            if leer(c2, a.slave, REG_ESTADO) == est:
                print(f"  [OK] estado restaurado (reg31={est})")
            else:
                print(f"  [!] NO se pudo restaurar reg31={est}: la placa se queda en BYPASS.")
                print(f"      Hazlo a mano a {a.vel} baud o con el menu de firmware.sh.")
    else:
        # AQUI ESTABA EL FALLO GRAVE: esta rama no restauraba el estado, asi que una
        # placa que se habia puesto en BYPASS para escribir la velocidad se quedaba
        # en bypass — sin regular — si la verificacion fallaba. Paso en el equipo
        # 00152 (SOLIDUS): L1 se quedo en bypass y el cliente estuvo una fase sin
        # regular hasta que se vio en la telemetria al dia siguiente.
        print(f"  [!] no contesta a {a.vel}. Probando si sigue a {a.baud}...")
        c2.close()
        c3 = abrir(a.port, a.baud)
        vive = bool(c3) and leer(c3, a.slave, REG_VEL, intentos=8) is not None
        if vive:
            print(f"  [i] sigue a {a.baud}: el cambio de velocidad NO se aplico.")
        else:
            print(f"  [X] no contesta a ninguna de las dos velocidades.")
        if est != 0:
            print(f"  [~] sacando la placa de BYPASS (reg31={est})...")
            restaurado = False
            for cli in (c3, c2):
                if not cli:
                    continue
                try:
                    llaves(cli, a.slave)
                    escribir_silencioso(cli, a.slave, REG_ESTADO, est)
                    time.sleep(0.4)
                    if leer(cli, a.slave, REG_ESTADO) == est:
                        restaurado = True
                        break
                except Exception:
                    pass
            if restaurado:
                print(f"  [OK] estado restaurado: la placa vuelve a regular")
            else:
                print(f"\n  ##############################################################")
                print(f"  ##  ATENCION: L{a.slave} PUEDE HABER QUEDADO EN BYPASS       ##")
                print(f"  ##  Eso significa que ESA FASE NO ESTA REGULANDO.           ##")
                print(f"  ##  Sacala ya:                                              ##")
                print(f"  ##    python3 espabila_placas.py --barrer --estado {est}            ##")
                print(f"  ##  Y comprueba con:  --buscar  (reg31 tiene que ser {est})        ##")
                print(f"  ##############################################################\n")
        if c3: c3.close()
    print("\n  Recuerda: el flow sigue hablando a su velocidad de siempre.")
    print("  sudo systemctl start nodered")


if __name__ == '__main__':
    main()
