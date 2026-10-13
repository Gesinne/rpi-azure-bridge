#!/usr/bin/env python3
"""
Cambia la velocidad Modbus con la que HABLA el flow de Node-RED.

POR QUE
Cuando las placas quedan a una velocidad y el flow a otra, el flow pregunta y
nadie contesta: "Timed out" y "Modbus queue cleared on reconnect" en bucle.
Hay dos formas de arreglarlo y casi siempre es mejor esta:

  - Mover las PLACAS a la velocidad del flow: hay que escribir el registro 61 en
    cada una, con bypass y llaves, y si una escritura se queda a medias la placa
    se queda inaccesible. Riesgo real.
  - Mover el FLOW a la velocidad de las placas: se edita un fichero y se reinicia
    Node-RED. Reversible y sin tocar hardware. ESTO.

Caso que lo motivo (equipo 00128, 13-oct-2026): L1 y L3 vivas a 38400 — el escaner
extendido las encontro— y el flow hablando a 115200 desde una intervencion del 7 de
octubre. El equipo paso de 130.000 mensajes diarios a 300.

Hace copia del flows.json antes de tocarlo y reinicia Node-RED.

OJO: si luego se hace "Actualizar Flow" (baja del repo NODERED) esto se revierte.
Para que sea permanente hay que commitearlo en el repo NODERED.

Uso:
    sudo python3 cambia_baudrate_flow.py --ver          # que velocidad usa ahora
    sudo python3 cambia_baudrate_flow.py --vel 38400
    sudo python3 cambia_baudrate_flow.py --vel 115200   # volver
"""
import argparse, glob, json, os, shutil, subprocess, sys, time

CANDIDATOS = ['/home/gesinne/.node-red/flows.json', '/home/pi/.node-red/flows.json',
              '/root/.node-red/flows.json']


def localiza(ruta=None):
    if ruta:
        return ruta if os.path.exists(ruta) else None
    for c in CANDIDATOS:
        if os.path.exists(c):
            return c
    g = glob.glob('/home/*/.node-red/flows.json')
    return g[0] if g else None


def campos_baud(nodo):
    """Cualquier clave con 'baud': el nombre cambia entre versiones del nodo."""
    return [k for k in nodo if 'baud' in k.lower()]


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--vel', type=int, choices=(115200, 57600, 38400, 19200, 9600))
    p.add_argument('--ver', action='store_true', help='solo mirar')
    p.add_argument('--flow', help='ruta del flows.json')
    p.add_argument('--no-reinicio', action='store_true')
    a = p.parse_args()

    ruta = localiza(a.flow)
    if not ruta:
        print('[X] no encuentro flows.json'); sys.exit(1)
    print(f'  flow: {ruta}')

    with open(ruta, encoding='utf-8') as f:
        flow = json.load(f)

    nodos = [n for n in flow if 'modbus' in str(n.get('type', '')).lower()]
    clientes = [n for n in nodos if campos_baud(n)]
    if not clientes:
        print('[X] ningun nodo modbus con campo de baudrate'); sys.exit(1)

    for n in clientes:
        for k in campos_baud(n):
            print(f"    {n.get('type')} '{n.get('name', '')}': {k} = {n[k]}"
                  f"   (puerto: {n.get('serialPort', '?')})")

    if a.ver or a.vel is None:
        return

    actuales = {str(n[k]) for n in clientes for k in campos_baud(n)}
    if actuales == {str(a.vel)}:
        print(f'  [i] el flow ya habla a {a.vel}. Nada que hacer.'); return

    copia = f'{ruta}.antes-de-{a.vel}-{time.strftime("%Y%m%d-%H%M%S")}'
    shutil.copy2(ruta, copia)
    print(f'  copia de seguridad: {copia}')

    n_cambios = 0
    for n in clientes:
        for k in campos_baud(n):
            if str(n[k]) != str(a.vel):
                # se respeta el tipo original: unas versiones lo guardan como texto
                n[k] = str(a.vel) if isinstance(n[k], str) else a.vel
                n_cambios += 1

    with open(ruta, 'w', encoding='utf-8') as f:
        json.dump(flow, f, ensure_ascii=False)
    print(f'  [OK] {n_cambios} campo(s) a {a.vel}')

    if not a.no_reinicio:
        print('  reiniciando Node-RED...')
        subprocess.run(['systemctl', 'restart', 'nodered'], stderr=subprocess.DEVNULL)
        time.sleep(3)
        print('  listo. Mira si siguen los errores:')
        print('    sudo journalctl -u nodered --since "2 min ago" -o cat | grep -cE "Timed out|queue cleared"')


if __name__ == '__main__':
    main()
