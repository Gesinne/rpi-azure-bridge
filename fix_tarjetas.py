#!/usr/bin/env python3
"""
Habilita o deshabilita la lectura Modbus de las tarjetas (L1/L2/L3) en el flow.

Generaliza fix_deshabilitar_L2.py, que solo sabia con la Tarjeta2.

PARA QUE SIRVE: cuando una placa no contesta, su timeout mete el cliente Modbus
en reconexion permanente ("Modbus queue cleared on reconnect") y degrada la
lectura de las demas. Deshabilitar su getter deja de preguntarle y las otras se
leen limpias.

OJO: deshabilitar NO aisla electricamente. La placa sigue colgada del par, asi
que si esta dominando el bus, esto no lo arregla.

Uso:
    sudo python3 fix_tarjetas.py --listar          # que hay ahora, sin tocar nada
    sudo python3 fix_tarjetas.py --off 2           # deja de leer L2
    sudo python3 fix_tarjetas.py --off 2,3
    sudo python3 fix_tarjetas.py --on 2            # volver a leerla
    sudo python3 fix_tarjetas.py --solo 1          # SOLO L1 activa (para aislar)
    sudo python3 fix_tarjetas.py --todas           # todas habilitadas

Hace backup del flows.json y reinicia Node-RED (--no-reinicio para no hacerlo).

OJO: si luego se hace "Actualizar Flow" (baja del repo NODERED) esto se
revierte. Para que sea permanente hay que commitearlo en el repo NODERED.
"""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import time

TIPO = 'modbus-flex-getter'


def localiza_flow():
    cands = glob.glob('/home/*/.node-red/flows.json') + ['/root/.node-red/flows.json']
    return next((p for p in cands if os.path.exists(p)), None)


def getters_por_tarjeta(flows):
    """{numero_de_tarjeta: [nodos]} por nombre TarjetaN, con fallback a unitid."""
    out = {}
    for n in flows:
        if n.get('type') != TIPO:
            continue
        nombre = str(n.get('name', '')).lower()
        num = None
        for i in (1, 2, 3):
            if 'tarjeta%d' % i in nombre:
                num = i
                break
        if num is None:
            try:
                num = int(str(n.get('unitid', '')))
            except ValueError:
                continue
        out.setdefault(num, []).append(n)
    return out


def main():
    p = argparse.ArgumentParser()
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument('--listar', action='store_true')
    g.add_argument('--off', help='tarjetas a deshabilitar, ej: 2  o  2,3')
    g.add_argument('--on', help='tarjetas a habilitar')
    g.add_argument('--solo', help='deja SOLO esa(s) habilitada(s), el resto off')
    g.add_argument('--todas', action='store_true', help='habilita todas')
    p.add_argument('--flow', help='ruta del flows.json (por defecto se busca)')
    p.add_argument('--no-reinicio', action='store_true',
                   help='no parar/arrancar Node-RED (para cadenas de cambios)')
    args = p.parse_args()

    f = args.flow or localiza_flow()
    if not f:
        print("[X] no encuentro flows.json"); sys.exit(1)
    print("[i] flow:", f)

    with open(f) as fh:
        flows = json.load(fh)

    porT = getters_por_tarjeta(flows)
    if not porT:
        print("[X] no hay getters '%s' en el flow. Nada que hacer." % TIPO); sys.exit(1)

    def estado(num):
        return "OFF" if any(n.get('d') for n in porT[num]) else "ON"

    print("[i] estado actual:")
    for num in sorted(porT):
        print("    L%d: %s  (%s)" % (num, estado(num),
              ", ".join(str(n.get('name') or n.get('id')) for n in porT[num])))

    if args.listar:
        return

    def pedidas(v):
        nums = []
        for x in str(v).split(','):
            x = x.strip()
            if not x:
                continue
            if not x.isdigit() or int(x) not in porT:
                print("[X] tarjeta '%s' no existe en el flow (hay: %s)"
                      % (x, ", ".join("L%d" % n for n in sorted(porT)))); sys.exit(1)
            nums.append(int(x))
        return nums

    objetivo = {}   # num -> True(ON) / False(OFF)
    if args.todas:
        objetivo = {n: True for n in porT}
    elif args.solo:
        deja = pedidas(args.solo)
        objetivo = {n: (n in deja) for n in porT}
    elif args.off:
        objetivo = {n: False for n in pedidas(args.off)}
    elif args.on:
        objetivo = {n: True for n in pedidas(args.on)}

    cambios = [(n, v) for n, v in objetivo.items() if (estado(n) == "ON") != v]
    if not cambios:
        print("[!] ya esta asi. No se toca el flow.")
        return

    if not args.no_reinicio:
        print("[!] Parando Node-RED para editar el flow...")
        subprocess.run(['systemctl', 'stop', 'nodered'], stderr=subprocess.DEVNULL)
        time.sleep(2)

    bak = f + '.bak.' + time.strftime('%Y%m%d-%H%M%S')
    shutil.copy2(f, bak)
    print("[i] backup:", bak)

    for num, on in sorted(objetivo.items()):
        for n in porT[num]:
            if on:
                n.pop('d', None)
            else:
                n['d'] = True
        print("  [OK] L%d -> %s" % (num, "ON" if on else "OFF"))

    with open(f, 'w') as fh:
        json.dump(flows, fh)

    if not args.no_reinicio:
        print("[~] Reiniciando Node-RED...")
        subprocess.run(['systemctl', 'start', 'nodered'], stderr=subprocess.DEVNULL)
    print("[OK] Listo. Comprueba:  sudo journalctl -u nodered -n 30 --no-pager -o cat")


if __name__ == '__main__':
    main()
