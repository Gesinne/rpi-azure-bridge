#!/usr/bin/env python3
"""
Trocea la lectura de la fase 3 en el flow de Node-RED de este equipo.

POR QUE: cuando al bus RS-485 le falta la resistencia del par, las tramas largas
se pierden. Pidiendo 67 registros de golpe (38 ms) solo llega el 8%; pidiendo los
22 de tiempo real (15 ms) llega mucho mas. La configuracion (22-66) no cambia, asi
que se lee una de cada diez vueltas. El resto del flow sigue recibiendo los 67
registros de siempre, reconstruidos.

  sudo python3 trocear_fase3.py            # aplica
  sudo python3 trocear_fase3.py --revertir # deja el flow como estaba
"""
import json, os, shutil, subprocess, sys, time

FLOWS = os.path.expanduser('~gesinne/.node-red/flows.json')
NUEVO = 'f3juntar0001'

F19 = '''let cantidad = global.get("cantidad_registros_3");
if (typeof cantidad !== "number" || isNaN(cantidad)) {
    cantidad = 67;
    global.set("cantidad_registros_3", cantidad);
}

msg.topic = "Leer3";

// lectura completa pedida desde el dashboard: no se trocea
if (cantidad !== 67) {
    msg.payload = { value: 0, fc: 3, unitid: 3, address: 0, quantity: cantidad };
    return msg;
}

let n = (context.get("ciclo3") || 0) + 1;
context.set("ciclo3", n);

const bloque = (n % 10 === 0)
    ? { address: 22, quantity: 45 }   // configuracion
    : { address: 0,  quantity: 22 };  // tiempo real

msg.payload = { value: 0, fc: 3, unitid: 3, address: bloque.address, quantity: bloque.quantity };
return msg;
'''

JUNTAR = '''let buf = context.get("buf3");
if (!Array.isArray(buf) || buf.length < 67) buf = new Array(67).fill(0);

const v = msg.payload;
if (!Array.isArray(v)) return null;

if (v.length >= 67) {
    buf = v.slice();
} else if (v.length === 22) {
    for (let i = 0; i < 22; i++) buf[i] = v[i];
} else if (v.length === 45) {
    for (let i = 0; i < 45; i++) buf[22 + i] = v[i];
} else {
    return null;
}

context.set("buf3", buf);
msg.payload = buf;
return msg;
'''

def salir(msg):
    print('[X] ' + msg)
    sys.exit(1)

def cargar():
    if not os.path.exists(FLOWS):
        salir('no encuentro %s' % FLOWS)
    with open(FLOWS, encoding='utf-8') as f:
        return json.load(f)

def guardar(d, etiqueta):
    copia = '%s.bak-%s-%s' % (FLOWS, etiqueta, time.strftime('%Y%m%d%H%M%S'))
    shutil.copy2(FLOWS, copia)
    print('  copia de seguridad: %s' % copia)
    tmp = FLOWS + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False)
    os.replace(tmp, FLOWS)
    st = os.stat(os.path.dirname(FLOWS))
    os.chown(FLOWS, st.st_uid, st.st_gid)

def reiniciar():
    print('  reiniciando Node-RED...')
    subprocess.run(['systemctl', 'restart', 'nodered'], check=False)

def aplicar():
    d = cargar()
    f19 = next((n for n in d if n.get('type') == 'function' and n.get('name') == 'function 19'), None)
    tar = next((n for n in d if n.get('type') == 'modbus-flex-getter' and n.get('name') == 'Tarjeta3'), None)
    if not f19: salir('no encuentro la funcion "function 19" (la que pide los registros de la fase 3)')
    if not tar: salir('no encuentro el getter "Tarjeta3"')
    if any(n.get('id') == NUEVO for n in d):
        salir('ya esta aplicado (existe el nodo "Juntar Fase 3"). Usa --revertir para deshacerlo.')
    if 'cantidad_registros_3' not in (f19.get('func') or ''):
        salir('la "function 19" de este equipo no es la esperada; no toco nada')

    destinos = list((tar.get('wires') or [[]])[0])   # a donde iba la respuesta
    if not destinos: salir('el getter Tarjeta3 no tiene salida conectada; no toco nada')
    print('  la respuesta de Tarjeta3 iba a: %s' % ', '.join(destinos))

    nodo = {'id': NUEVO, 'type': 'function', 'z': tar.get('z'), 'name': 'Juntar Fase 3',
            'func': JUNTAR, 'outputs': 1, 'timeout': 0, 'noerr': 0,
            'initialize': '', 'finalize': '', 'libs': [],
            'x': (tar.get('x') or 0) + 170, 'y': (tar.get('y') or 0) + 80,
            'wires': [destinos]}
    if tar.get('g'): nodo['g'] = tar['g']

    f19['func'] = F19
    tar['wires'][0] = [NUEVO]
    d.append(nodo)
    guardar(d, 'pre-troceado')
    print('  function 19: troceado puesto')
    print('  Tarjeta3 -> Juntar Fase 3 -> %s' % ', '.join(destinos))
    reiniciar()
    print('[OK] aplicado. Avisa para medir dentro de 10 minutos.')

def revertir():
    d = cargar()
    nodo = next((n for n in d if n.get('id') == NUEVO), None)
    if not nodo: salir('no esta aplicado (no existe "Juntar Fase 3")')
    tar = next((n for n in d if n.get('type') == 'modbus-flex-getter' and n.get('name') == 'Tarjeta3'), None)
    f19 = next((n for n in d if n.get('type') == 'function' and n.get('name') == 'function 19'), None)
    destinos = list((nodo.get('wires') or [[]])[0])
    if tar: tar['wires'][0] = destinos
    if f19:
        f19['func'] = ('let cantidad = global.get("cantidad_registros_3");\n'
                       'if (typeof cantidad !== "number" || isNaN(cantidad)) {\n'
                       '    cantidad = 67;\n    global.set("cantidad_registros_3", cantidad);\n}\n\n'
                       'msg.topic = "Leer3";\nmsg.payload = {\n    value: 0,\n    fc: 3,\n    unitid: 3,\n'
                       '    address: 0,\n    quantity: global.get("cantidad_registros_3")\n};\n\nreturn msg;\n')
    d = [n for n in d if n.get('id') != NUEVO]
    guardar(d, 'pre-revertir')
    print('  Tarjeta3 -> %s (como estaba)' % ', '.join(destinos))
    reiniciar()
    print('[OK] revertido.')

if __name__ == '__main__':
    if os.geteuid() != 0: salir('ejecutalo con sudo')
    (revertir if '--revertir' in sys.argv else aplicar)()
