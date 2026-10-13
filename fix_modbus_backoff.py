#!/usr/bin/env python3
"""
Parcheador de flows.json — que una placa muda no bloquee la cola de lectura.

EL PROBLEMA, EN LA MECANICA DEL FUNCTION "Modbus Queue"
La cola es serie: manda una peticion y espera un msg.topic="next" para mandar la
siguiente. Ese "next" llega CON LA RESPUESTA. Si una placa no contesta:
  - el "next" no llega nunca -> la cola se queda BLOQUEADA, y
  - el unico rescate (`resendifnoresponse`, cada `resendinterval`=10 s) REENVIA LA
    MISMA peticion a la placa muda, en vez de pasar a la siguiente.
La cola entera queda presa de esa tarjeta. Medido en el 00128: L1 colaba 2-4
mensajes por minuto (lo normal son 63) y L3 solo "de vez en cuando"; el arranque
tarda porque los tres getters tienen delayOnStart de 10 s y encima la cola se
bloquea en el primer fallo.

EL ARREGLO (todo dentro del propio function, sin tocar el resto del flow)
  - Se cuentan los reenvios por tarjeta. Tras `maxresends` sin respuesta, esa
    peticion se DESCARTA y la cola AVANZA a la siguiente.
  - Esa tarjeta queda penalizada `penaltysecs`: durante ese rato no se encola, asi
    que el ciclo se queda con las placas vivas. Se reintenta sola al vencer, de
    modo que si vuelve se recupera sin tocar nada. NO hay que desactivarla a mano.
  - `resendinterval` baja de 10 s a 5 s: en un bus con perdidas, insistir rapido
    es lo que mas rinde (con un 11% de exito por intento, 3 intentos dan 30%).

Uso:
    python3 fix_modbus_backoff.py <flows.json> [--check|--apply|--remove]
"""
import json, shutil, sys, time

MARCA = 'maxresends'          # si esta, ya se aplico

CAMBIOS = [
    # 1) parametros nuevos y reintento mas rapido
    ("""    resendinterval: 10,""",
     """    resendinterval: 5,        // antes 10: en un bus con perdidas, insistir rapido rinde
    maxresends: 2,            // tras 2 reenvios sin respuesta se descarta y se AVANZA
    penaltysecs: 60,          // y esa tarjeta no se vuelve a pedir en 60 s"""),

    # 2) contexto: fallos y penalizaciones por tarjeta
    ("""let { queue, state, lastupdate, sent, lastmsg } = contextData;""",
     """let { queue, state, lastupdate, sent, lastmsg, resends, penal } = contextData;"""),

    ("""        lastmsg: context.get("lastmsg")
    };""",
     """        lastmsg: context.get("lastmsg"),
        resends: context.get("resends") || {},
        penal: context.get("penal") || {}
    };"""),

    ("""    context.set("lastmsg", data.lastmsg);""",
     """    context.set("lastmsg", data.lastmsg);
    context.set("resends", data.resends);
    context.set("penal", data.penal);"""),

    # 3) una respuesta buena limpia el castigo de esa tarjeta
    ("""    case "next":
        contextData.lastupdate = current;
        contextData.sent = false;
        sendNextCommand();
        break;""",
     """    case "next":
        contextData.lastupdate = current;
        contextData.sent = false;
        // ha contestado: se le perdona todo a esa tarjeta
        if (lastmsg && lastmsg.payload && lastmsg.payload.unitid !== undefined) {
            delete contextData.resends[lastmsg.payload.unitid];
            delete contextData.penal[lastmsg.payload.unitid];
        }
        sendNextCommand();
        break;"""),

    # 4) el rescate: contar, y tras maxresends descartar y AVANZAR
    ("""    if (CONFIG.resendifnoresponse && seconds > 0 && seconds % CONFIG.resendinterval === 0 && lastmsg && sent) {
        notifmsg.payload.resend = true;""",
     """    if (CONFIG.resendifnoresponse && seconds > 0 && seconds % CONFIG.resendinterval === 0 && lastmsg && sent) {
        const uid = lastmsg.payload && lastmsg.payload.unitid;
        const n = (contextData.resends[uid] || 0) + 1;
        contextData.resends[uid] = n;
        if (n > CONFIG.maxresends) {
            // esta tarjeta no contesta: se descarta su peticion, se la penaliza y
            // la cola SIGUE con las demas en vez de quedarse presa de ella
            contextData.penal[uid] = current + CONFIG.penaltysecs * 1000;
            contextData.resends[uid] = 0;
            contextData.sent = false;
            contextData.lastmsg = undefined;
            contextData.queue = queue.filter(it => !(it.payload && it.payload.unitid === uid));
            node.warn(`L${uid} no responde: fuera del ciclo ${CONFIG.penaltysecs} s`);
            updateStatus("yellow", "ring", `L${uid} penalizada ${CONFIG.penaltysecs}s`);
            sendNextCommand();
            return notifmsg;
        }
        notifmsg.payload.resend = true;"""),

    # 5) no encolar lo de una tarjeta penalizada
    ("""function handleModbusRequest(msg) {
    contextData.queue = queue.filter(item => item.topic !== msg.topic);""",
     """function handleModbusRequest(msg) {
    const uid = msg.payload && msg.payload.unitid;
    const hasta = contextData.penal[uid];
    if (hasta && Date.now() < hasta) return;      // penalizada: no se le pide nada
    if (hasta) delete contextData.penal[uid];     // ya vencio el castigo: se reintenta
    contextData.queue = queue.filter(item => item.topic !== msg.topic);"""),
]


def nodo_cola(flow):
    for n in flow:
        if isinstance(n, dict) and n.get('name') == 'Modbus Queue':
            return n
    return None


def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    ruta = sys.argv[1]
    modo = sys.argv[2] if len(sys.argv) > 2 else '--check'

    with open(ruta, encoding='utf-8') as f:
        flow = json.load(f)
    n = nodo_cola(flow)
    if not n:
        print('[X] no encuentro el function "Modbus Queue"'); sys.exit(1)

    func = n.get('func', '')
    aplicado = MARCA in func
    print(f'  function "Modbus Queue": {len(func)} caracteres')
    print(f'  estado: {"YA APLICADO" if aplicado else "SIN APLICAR"}')

    if modo == '--check':
        return
    if modo == '--apply' and aplicado:
        print('  nada que hacer'); return
    if modo == '--remove' and not aplicado:
        print('  no estaba aplicado'); return

    pares = CAMBIOS if modo == '--apply' else [(b, a) for a, b in CAMBIOS]
    nuevo, hechos = func, 0
    for viejo, reemplazo in pares:
        if viejo not in nuevo:
            print(f'  [X] no encuentro este trozo, ABORTO sin tocar nada:\n      {viejo.strip()[:70]}...')
            sys.exit(1)
        nuevo = nuevo.replace(viejo, reemplazo, 1)
        hechos += 1

    copia = f'{ruta}.antes-del-backoff-{time.strftime("%Y%m%d-%H%M%S")}'
    shutil.copy2(ruta, copia)
    n['func'] = nuevo
    with open(ruta, 'w', encoding='utf-8') as f:
        json.dump(flow, f, ensure_ascii=False)
    print(f'  copia: {copia}')
    print(f'  [OK] {hechos} cambio(s) en el function. Reinicia Node-RED.')


if __name__ == '__main__':
    main()
