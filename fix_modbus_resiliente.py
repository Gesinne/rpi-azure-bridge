#!/usr/bin/env python3
"""
Parcheador de flows.json — que una placa muerta no tumbe a las demas (oct 2026).

PROBLEMA (medido en el equipo 00128, 13-oct-2026)
El flow lee las 3 tarjetas cada 0,5 s con UN solo cliente Modbus en serie, y ese
cliente viene configurado asi:

    clientTimeout      = 4500 ms
    reconnectOnTimeout = true
    reconnectTimeout   = 2000 ms

Con una placa que no contesta, cada intento cuesta 4.500 ms de espera + 2.000 ms
de reconexion = 6,5 s (el "Timed out" cada 7 s del log). Mientras espera, el flow
sigue encolando 6 peticiones por segundo —unas 39 se acumulan— y al reconectar
LIMPIA LA COLA ENTERA, tirando tambien las peticiones de las placas buenas. Es el
"Modbus queue cleared on reconnect" repetido: encolar -> esperar -> reconectar ->
tirar todo. Resultado: una sola placa averiada deja el equipo sin ninguna fase.
En el 00128 el refresco real medido fue de 67,6 s cuando lo normal es ~1 s.

Las placas responden en 6,7 ms con jitter 0,0 cuando les llega la pregunta, asi
que 4.500 ms de espera no protegen de nada: solo alargan el castigo.

ARREGLO
    reconnectOnTimeout -> false   un timeout es un timeout: se salta esa tarjeta
                                  y sigue con las demas, sin tirar la cola
    clientTimeout      -> 500 ms  75 veces el tiempo real de respuesta, de sobra

Con esto, una placa muerta cuesta 0,5 s por intento en vez de 6,5 s, y las otras
dos se leen limpias. No toca el baudrate ni el resto de la configuracion.

Uso:
    python3 fix_modbus_resiliente.py <flows.json> --check
    python3 fix_modbus_resiliente.py <flows.json> --apply
    python3 fix_modbus_resiliente.py <flows.json> --remove    # valores de antes
    python3 fix_modbus_resiliente.py <flows.json> --apply --ritmo 1
        --ritmo N  pone tambien los inject "Leer Tarjeta N" cada N segundos
                   (por defecto 0,5 s, que va al limite de lo que da el bus)
"""
import json, shutil, sys, time

NUEVO = {'reconnectOnTimeout': False, 'clientTimeout': 500}
VIEJO = {'reconnectOnTimeout': True, 'clientTimeout': 4500}


def clientes(flow):
    return [n for n in flow if 'modbus-client' in str(n.get('type', ''))]


def injects_tarjeta(flow):
    return [n for n in flow if n.get('type') == 'inject'
            and str(n.get('name', '')).lower().startswith('leer tarjeta')]


def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    ruta, modo = sys.argv[1], sys.argv[2]
    ritmo = None
    if '--ritmo' in sys.argv:
        ritmo = sys.argv[sys.argv.index('--ritmo') + 1]

    with open(ruta, encoding='utf-8') as f:
        flow = json.load(f)

    cl = clientes(flow)
    if not cl:
        print('[X] no hay nodo modbus-client en este flow'); sys.exit(1)

    for c in cl:
        print(f"  cliente '{c.get('name','')}': clientTimeout={c.get('clientTimeout')} "
              f"reconnectOnTimeout={c.get('reconnectOnTimeout')} "
              f"reconnectTimeout={c.get('reconnectTimeout')} baud={c.get('serialBaudrate')}")
    for i in injects_tarjeta(flow):
        print(f"  inject '{i.get('name')}': cada {i.get('repeat')} s")

    if modo == '--check':
        aplicado = all(str(c.get(k)).lower() == str(v).lower()
                       for c in cl for k, v in NUEVO.items())
        print('  estado:', 'YA APLICADO' if aplicado else 'SIN APLICAR')
        return

    destino = NUEVO if modo == '--apply' else VIEJO if modo == '--remove' else None
    if destino is None:
        print('[X] usa --check, --apply o --remove'); sys.exit(1)

    copia = f'{ruta}.antes-resiliente-{time.strftime("%Y%m%d-%H%M%S")}'
    shutil.copy2(ruta, copia)
    print(f'  copia de seguridad: {copia}')

    n = 0
    for c in cl:
        for k, v in destino.items():
            if c.get(k) != v:
                print(f"    {k}: {c.get(k)} -> {v}")
                c[k] = v
                n += 1
    if ritmo:
        for i in injects_tarjeta(flow):
            if str(i.get('repeat')) != str(ritmo):
                print(f"    inject '{i.get('name')}': {i.get('repeat')} -> {ritmo} s")
                i['repeat'] = str(ritmo)
                n += 1

    with open(ruta, 'w', encoding='utf-8') as f:
        json.dump(flow, f, ensure_ascii=False)
    print(f'  [OK] {n} cambio(s). Reinicia Node-RED:  sudo systemctl restart nodered')


if __name__ == '__main__':
    main()
