#!/usr/bin/env python3
"""
Parcheador de flows.json: que una placa muda no deje ciegas a las otras dos
(versión para la "Modbus Queue" de nov 2026, la que ya trae pause_ms).

EL PROBLEMA
  La cola manda una petición cada vez y espera a que vuelva (aciertos por
  "Advance queue" -> topic "next"; fallos por "Filtro error" -> msg.error).
  Tras CUALQUIER fallo hace una pausa global de 5 s y, en la vuelta siguiente,
  vuelve a preguntar a la placa muerta. Con una placa muda cada vuelta cuesta
  timeout + reconexión + 5 s de pausa, y las dos sanas apenas se leen (el
  "Timed out" cada 7 s en el log del 00152, nov 2026).

EL ARREGLO (solo dentro del function "Modbus Queue")
  - Por placa: tras 3 fallos de LECTURA seguidos se la deja en espera 2, 4, 8,
    16, 32 y luego 60 s; mientras, la cola pasa a las demás. Una placa FLOJA
    (que ha contestado en el último minuto) nunca espera más de 2 s, para no
    quitarle lecturas (caso L3 del 00133). Al primer acierto vuelve a leerse
    normal. Las ESCRITURAS no se retrasan nunca.
  - La pausa global tras un error baja de 5 s a 300 ms (simulado: mejor que 1 s
    con placas flojas, igual con placas muertas; 200 ms ya no mejora).
  Va junto con fix_modbus_resiliente.py (timeout 500 ms sin reconexión).

Uso:
    python3 fix_cola_modbus.py <flows.json> [--check|--apply|--remove]
    --check   exit 0 si está aplicado, 1 si no
    --apply   aplica (idempotente). Si la cola no es la esperada, no toca nada (exit 3)
    --remove  deja la cola exactamente como estaba
"""
import json
import os
import sys

# Versión vigente. Las anteriores se reconocen y se sustituyen solas al aplicar.
MARCA = '// [gesinne-backoff v2]'
CAMBIOS = [
    [
        "    pause_ms: 5000 // pausa global tras un error del cliente/getter/write\n",
        "    pause_ms: 300, // pausa global tras un error del cliente/getter/write // [gesinne-backoff v2] antes 5000\n    backoff_max_s: 60 // [gesinne-backoff v2] espera máxima de una placa que no contesta\n"
    ],
    [
        "    contextData.sent = false;\n    contextData.pausedUntil = now + CONFIG.pause_ms;\n",
        "    contextData.sent = false;\n    marcarFallo(now); // [gesinne-backoff v2]\n    contextData.pausedUntil = now + CONFIG.pause_ms;\n"
    ],
    [
        "        contextData.lastupdate = current;\n        contextData.sent = false;\n        sendNextCommand();\n",
        "        contextData.lastupdate = current;\n        contextData.sent = false;\n        marcarExito(); // [gesinne-backoff v2]\n        sendNextCommand();\n"
    ],
    [
        "    let newmsg = queue.shift();\n",
        "    let newmsg = sacarSiguiente(); // [gesinne-backoff v2] antes: queue.shift()\n    if (!newmsg) return;\n"
    ]
]
FUNCIONES = "\n// [gesinne-backoff v2] una placa que no contesta se pregunta cada vez menos (hasta 1 vez por minuto)\n// y no frena a las demás; al primer acierto vuelve a leerse normal.\nfunction marcarFallo(now) {\n    const m = contextData.lastmsg;\n    if (!m || !m.payload || !CONFIG.readFCs.includes(m.payload.fc)) return;\n    const f = context.get('fallos') || {};\n    const u = m.payload.unitid;\n    const e = f[u] || { n: 0, ok: 0 };\n    e.n = (e.n || 0) + 1;\n    // espera solo tras 3 fallos seguidos: 2, 4, 8... hasta backoff_max_s\n    let espera = e.n < 3 ? 0 : Math.min(CONFIG.backoff_max_s, Math.pow(2, Math.min(e.n - 2, 6)));\n    // placa floja (ha contestado en el último minuto): nunca más de 2 s\n    if (e.ok && now - e.ok < 60000) espera = Math.min(espera, 2);\n    e.hasta = now + espera * 1000;\n    f[u] = e;\n    context.set('fallos', f);\n}\nfunction marcarExito() {\n    const m = contextData.lastmsg;\n    if (!m || !m.payload || !CONFIG.readFCs.includes(m.payload.fc)) return;\n    const f = context.get('fallos') || {};\n    f[m.payload.unitid] = { n: 0, ok: Date.now(), hasta: 0 };\n    context.set('fallos', f);\n}\nfunction sacarSiguiente() {\n    const f = context.get('fallos') || {};\n    const now = Date.now();\n    for (let i = 0; i < queue.length; i++) {\n        const p = queue[i].payload || {};\n        const enEspera = CONFIG.readFCs.includes(p.fc) && f[p.unitid] && now < f[p.unitid].hasta;\n        if (!enEspera) { const m = queue.splice(i, 1)[0]; contextData.queue = queue; return m; }\n    }\n    return null;\n}\n"

# v1 (23-nov-2026): esperaba también a las placas FLOJAS y les quitaba lecturas (L3 del 00133)
MARCA_V1 = '// [gesinne-backoff]'
CAMBIOS_V1 = [
    [
        "    pause_ms: 5000 // pausa global tras un error del cliente/getter/write\n",
        "    pause_ms: 1000, // pausa global tras un error del cliente/getter/write // [gesinne-backoff] antes 5000\n    backoff_max_s: 60 // [gesinne-backoff] espera máxima de una placa que no contesta\n"
    ],
    [
        "    contextData.sent = false;\n    contextData.pausedUntil = now + CONFIG.pause_ms;\n",
        "    contextData.sent = false;\n    marcarFallo(now); // [gesinne-backoff]\n    contextData.pausedUntil = now + CONFIG.pause_ms;\n"
    ],
    [
        "        contextData.lastupdate = current;\n        contextData.sent = false;\n        sendNextCommand();\n",
        "        contextData.lastupdate = current;\n        contextData.sent = false;\n        marcarExito(); // [gesinne-backoff]\n        sendNextCommand();\n"
    ],
    [
        "    let newmsg = queue.shift();\n",
        "    let newmsg = sacarSiguiente(); // [gesinne-backoff] antes: queue.shift()\n    if (!newmsg) return;\n"
    ]
]
FUNCIONES_V1 = "\n// [gesinne-backoff] una placa que no contesta se pregunta cada vez menos (hasta 1 vez por minuto)\n// y no frena a las demás; al primer acierto vuelve a leerse normal.\nfunction marcarFallo(now) {\n    const m = contextData.lastmsg;\n    if (!m || !m.payload || !CONFIG.readFCs.includes(m.payload.fc)) return;\n    const f = context.get('fallos') || {};\n    const u = m.payload.unitid;\n    const n = ((f[u] && f[u].n) || 0) + 1;\n    f[u] = { n: n, hasta: now + Math.min(CONFIG.backoff_max_s, Math.pow(2, Math.min(n, 6))) * 1000 };\n    context.set('fallos', f);\n}\nfunction marcarExito() {\n    const m = contextData.lastmsg;\n    if (!m || !m.payload) return;\n    const f = context.get('fallos') || {};\n    if (f[m.payload.unitid]) { delete f[m.payload.unitid]; context.set('fallos', f); }\n}\nfunction sacarSiguiente() {\n    const f = context.get('fallos') || {};\n    const now = Date.now();\n    for (let i = 0; i < queue.length; i++) {\n        const p = queue[i].payload || {};\n        const enEspera = CONFIG.readFCs.includes(p.fc) && f[p.unitid] && now < f[p.unitid].hasta;\n        if (!enEspera) { const m = queue.splice(i, 1)[0]; contextData.queue = queue; return m; }\n    }\n    return null;\n}\n"

VERSIONES_VIEJAS = [(MARCA_V1, CAMBIOS_V1, FUNCIONES_V1)]

def cola(flows):
    qs = [n for n in flows if isinstance(n, dict) and n.get("type") == "function" and n.get("name") == "Modbus Queue"]
    return qs


def aplicado(func):
    return MARCA in func


def version_vieja(func):
    for v in VERSIONES_VIEJAS:
        if v[0] in func and MARCA not in func:
            return v
    return None


def quitar_version(func, cambios, funciones):
    if func.endswith(funciones):
        func = func[: -len(funciones)]
    for viejo, nuevo in cambios:
        func = func.replace(nuevo, viejo)
    return func


def aplicar(func):
    for viejo, _ in CAMBIOS:
        if func.count(viejo) != 1:
            return None, viejo
    for viejo, nuevo in CAMBIOS:
        func = func.replace(viejo, nuevo)
    return func + FUNCIONES, None


def quitar(func):
    v = version_vieja(func)
    if v:
        return quitar_version(func, v[1], v[2])
    return quitar_version(func, CAMBIOS, FUNCIONES)


def guardar(path, flows):
    tmp = path + ".tmp-cola"
    with open(tmp, "w") as f:
        json.dump(flows, f, indent=4)
        f.flush()
        os.fsync(f.fileno())
    try:
        os.chmod(tmp, os.stat(path).st_mode & 0o7777)
    except OSError:
        pass
    os.replace(tmp, path)


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    path = sys.argv[1]
    modo = sys.argv[2] if len(sys.argv) > 2 else "--check"
    try:
        flows = json.load(open(path))
    except (OSError, ValueError) as e:
        print(f"  [X] No se puede leer {path}: {e}", file=sys.stderr)
        sys.exit(2)
    qs = cola(flows)
    if len(qs) != 1:
        print(f"  [X] Esperaba 1 'Modbus Queue' y hay {len(qs)}: no toco nada", file=sys.stderr)
        sys.exit(3)
    q = qs[0]

    if modo == "--check":
        sys.exit(0 if aplicado(q["func"]) else 1)
    if modo == "--apply":
        if aplicado(q["func"]):
            print("applied=0")
            return
        base = q["func"]
        v = version_vieja(base)
        if v:
            base = quitar_version(base, v[1], v[2])   # versión anterior -> se sustituye
        nuevo, falta = aplicar(base)
        if nuevo is None:
            print("  [X] La cola no es la esperada (no encuentro: %r): no toco nada" % falta.strip()[:60], file=sys.stderr)
            sys.exit(3)
        q["func"] = nuevo
        guardar(path, flows)
        print("applied=1")
    elif modo == "--remove":
        if not aplicado(q["func"]) and not version_vieja(q["func"]):
            print("removed=0")
            return
        q["func"] = quitar(q["func"])
        guardar(path, flows)
        print("removed=1")
    else:
        print(f"Modo desconocido: {modo}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
