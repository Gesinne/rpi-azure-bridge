#!/usr/bin/env python3
"""
Arregla de una vez todo lo que esta mal en el flow (oct 2026).

POR QUE EXISTE ESTE Y NO BASTAN LOS fix_*.py DE ANTES
Los fix_*.py localizan los nodos **por id**. El flow 20261007 se exporto con los
ids REGENERADOS, asi que todos ellos dejaron de encontrar nada: `aplicar_fixes.sh`
parecia aplicarse y no tocaba nada, y los bugs ya arreglados en julio volvieron en
octubre sin que nadie se enterara. Este busca los nodos **por tipo y nombre**, asi
que sobrevive a una reexportacion.

QUE ARREGLA (comprobado sobre 20261007)
 1. La cola se queda clavada: el `join` count=2 + "Check messages match" emparejan
    sending/completed POR POSICION. Tras una desconexion queda un "completed"
    suelto y el guaranteed-delivery no recibe nunca OK/FAIL -> waitingForOKFail
    para siempre. Se sustituyen por el function "Correlar por id", que empareja
    por id (codigo reutilizado de fix_mqtt_delivery.py).
 2. El boton "Borrar Cola de Envio" no borraba nada: hacia
    `stop kiosk && pcmanfm <context> && stop nodered`, o sea abria un explorador
    grafico invisible en remoto y PARABA Node-RED. Pasa a borrar el context del
    nodo de la cola y reiniciar.
 3. Tres inject "hola" cada 0,5 s, activos: publicaban payloads Modbus fantasma
    que enmascaraban fallos reales. Se deshabilitan.
 5. Los datos no refrescan: el guaranteed-delivery envia de UNO EN UNO esperando
    confirmacion con timeout 30 s, y tiene maxQueue 2.000.000 (en disco). Con la
    confirmacion rota (bug 1), cada mensaje bloquea medio minuto; y con esa cola
    el dato de AHORA sale detras de todo lo acumulado, de ahi las rafagas de datos
    viejos y los huecos de minutos. Pasa a timeout 10 s y cola de 5.000 mensajes
    (~14 min de margen a 6 msg/s): se prioriza el dato actual.

 4. El cliente Modbus se autoboicotea: clientTimeout 4500 ms con
    reconnectOnTimeout, y al reconectar LIMPIA LA COLA, tirando las peticiones de
    las placas buenas. Una placa averiada deja el equipo sin ninguna fase. Pasa a
    clientTimeout 500 ms (las placas responden en 6,7 ms) y sin reconectar al
    timeout: asi NO hay que desactivar la placa mala.

Uso:
    python3 fix_flow_todo.py <flows.json> --check
    python3 fix_flow_todo.py <flows.json> --apply [--baud 38400]
        --baud  pone tambien esa velocidad en el cliente (la de las placas)
"""
import json, os, shutil, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from fix_mqtt_delivery import CORR_FUNC       # se reutiliza tal cual
except Exception:
    CORR_FUNC = None

CONTEXT_DIR = '/home/gesinne/.node-red/context'
CORR_ID = 'c0rre1arp0rid0001'


def localizar(flow):
    """Por tipo y nombre, nunca por id (ver el docstring)."""
    r = {'join': None, 'check': None, 'gd': None, 'sending': None, 'completed': None,
         'boton': None, 'hola': [], 'clientes': [], 'corr': None}
    for n in flow:
        if not isinstance(n, dict):
            continue
        t, nm = str(n.get('type', '')), str(n.get('name', ''))
        if t == 'join' and str(n.get('count')) == '2':
            r['join'] = n
        elif nm == 'Check messages match':
            r['check'] = n
        elif t == 'guaranteed-delivery':
            r['gd'] = n
        elif nm.startswith('key: sending'):
            r['sending'] = n
        elif nm.startswith('key: completed'):
            r['completed'] = n
        elif t == 'exec' and 'pcmanfm' in str(n.get('command', '')):
            r['boton'] = n
        elif t == 'inject' and str(n.get('payload')) == 'hola':
            r['hola'].append(n)
        elif 'modbus-client' in t:
            r['clientes'].append(n)
        elif 'Correlar por id' in nm:
            r['corr'] = n
    return r


def arregla_cola(flow, L):
    if L['corr']:
        return 0, 'cola: ya estaba arreglada'
    faltan = [k for k in ('join', 'check', 'gd', 'sending', 'completed') if not L[k]]
    if faltan:
        return 0, f"cola: no se puede, faltan nodos ({', '.join(faltan)})"
    if CORR_FUNC is None:
        return 0, 'cola: no se pudo importar CORR_FUNC de fix_mqtt_delivery.py'
    corr = {'id': CORR_ID, 'type': 'function', 'z': L['join'].get('z'),
            'g': L['join'].get('g'), 'name': 'Correlar por id (OK/FAIL)',
            'func': CORR_FUNC, 'outputs': 1, 'timeout': 0, 'noerr': 0,
            'initialize': '', 'finalize': '', 'libs': [],
            'x': L['join'].get('x', 3390), 'y': L['join'].get('y', 140),
            'wires': [[L['gd']['id']]]}
    # sending y completed pasaban por el join: ahora van al nodo nuevo
    for k in ('sending', 'completed'):
        for puerto in L[k].get('wires', []):
            for i, destino in enumerate(puerto):
                if destino == L['join']['id']:
                    puerto[i] = CORR_ID
    fuera = {L['join']['id'], L['check']['id']}
    flow[:] = [n for n in flow if not (isinstance(n, dict) and n.get('id') in fuera)]
    flow.append(corr)
    return 1, 'cola: join + "Check messages match" -> "Correlar por id"'


def arregla_boton(flow, L):
    if not L['boton']:
        return 0, 'boton: ya arreglado (o no esta)'
    if not L['gd']:
        return 0, 'boton: no encuentro el nodo de la cola'
    L['boton']['command'] = (f"sudo rm -rf {CONTEXT_DIR}/{L['gd']['id']}"
                             f" && sudo systemctl restart nodered")
    return 1, 'boton: ahora borra la cola de verdad (antes paraba Node-RED)'


def arregla_hola(flow, L):
    n = 0
    for h in L['hola']:
        if not h.get('d'):
            h['d'] = True
            n += 1
    return n, (f'{n} inject "hola" deshabilitados' if n else 'inject "hola": ya estaban fuera')


def arregla_entrega(flow, L):
    """Que el dato de ahora no espere detras de dias de cola."""
    if not L['gd']:
        return 0, 'entrega: no encuentro el nodo de la cola'
    n, detalle = 0, []
    for k, v in (('timeout', 10), ('maxQueue', 5000)):
        if L['gd'].get(k) != v:
            detalle.append(f"{k}: {L['gd'].get(k)} -> {v}")
            L['gd'][k] = v
            n += 1
    return n, ('entrega: ' + '; '.join(detalle) if detalle else 'entrega: ya estaba bien')


def arregla_modbus(flow, L, baud=None):
    n = 0
    detalle = []
    for c in L['clientes']:
        for k, v in (('reconnectOnTimeout', False), ('clientTimeout', 500)):
            if c.get(k) != v:
                detalle.append(f'{k}: {c.get(k)} -> {v}')
                c[k] = v
                n += 1
        if baud and str(c.get('serialBaudrate')) != str(baud):
            detalle.append(f"serialBaudrate: {c.get('serialBaudrate')} -> {baud}")
            c['serialBaudrate'] = (str(baud) if isinstance(c.get('serialBaudrate'), str)
                                   else int(baud))
            n += 1
    return n, ('modbus: ' + '; '.join(detalle) if detalle else 'modbus: ya estaba bien')


def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    ruta, modo = sys.argv[1], sys.argv[2]
    baud = None
    if '--baud' in sys.argv:
        baud = sys.argv[sys.argv.index('--baud') + 1]

    with open(ruta, encoding='utf-8') as f:
        flow = json.load(f)
    L = localizar(flow)

    print('  lo que hay en el flow:')
    print(f"    cola (guaranteed-delivery): {L['gd']['id'] if L['gd'] else 'NO ESTA'}")
    print(f"    join por posicion: {'SI (bug)' if L['join'] else 'no'}"
          f"   | 'Correlar por id': {'si' if L['corr'] else 'NO'}")
    print(f"    boton con pcmanfm: {'SI (bug)' if L['boton'] else 'no'}")
    print(f"    inject 'hola' activos: {len([h for h in L['hola'] if not h.get('d')])} de {len(L['hola'])}")
    if L['gd']:
        print(f"    entrega: timeout={L['gd'].get('timeout')} s  maxQueue={L['gd'].get('maxQueue')}")
    for c in L['clientes']:
        print(f"    cliente modbus: baud={c.get('serialBaudrate')} "
              f"timeout={c.get('clientTimeout')} reconnectOnTimeout={c.get('reconnectOnTimeout')}")

    if modo == '--check':
        return
    if modo != '--apply':
        print('[X] usa --check o --apply'); sys.exit(1)

    copia = f'{ruta}.antes-del-fix-{time.strftime("%Y%m%d-%H%M%S")}'
    shutil.copy2(ruta, copia)
    print(f'\n  copia de seguridad: {copia}\n')

    total = 0
    for fn, args in ((arregla_cola, (flow, L)), (arregla_boton, (flow, L)),
                     (arregla_hola, (flow, L)), (arregla_entrega, (flow, L)),
                     (arregla_modbus, (flow, L, baud))):
        n, msg = fn(*args)
        total += n
        print(f"  [{'OK' if n else '--'}] {msg}")

    if total:
        with open(ruta, 'w', encoding='utf-8') as f:
            json.dump(flow, f, ensure_ascii=False)
        print(f'\n  {total} cambio(s) escritos. Reinicia Node-RED.')
    else:
        print('\n  nada que cambiar: el flow ya estaba arreglado.')


if __name__ == '__main__':
    main()
