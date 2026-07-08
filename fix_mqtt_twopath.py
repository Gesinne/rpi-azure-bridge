#!/usr/bin/env python3
"""
Parcheador de flows.json — publicación MQTT por DOS CAMINOS (jul 2026).

OBJETIVO:
  Que el dato ACTUAL se publique en vivo sin esperar detrás de la cola, y que
  la cola de recuperación acumule el máximo (sin perder datos) drenando en
  PARALELO. Antes todo pasaba por el guaranteed-delivery (cola FIFO en línea):
  tras un corte, el dato en vivo esperaba a que se reenviaran horas de backlog.

DISEÑO (grupo "Publishing to MQTT"):
  - VIVO: lectura -> mqtt out DIRECTO (cuando hay conexión).
  - Enrutado por estado: un nodo `status` sobre el mqtt out mantiene
    global.mqttOnline. Un `switch` tras "Limpia msg" manda:
        online  -> mqtt out           (vivo)
        offline -> guaranteed-delivery (recuperación / cola)
  - RECUPERACIÓN: el guaranteed-delivery (con el fix de correlar-por-id) sigue
    publicando por su cuenta; drena en paralelo. Al pasar de offline->online se
    le inyecta un FAIL para destrabarlo.
  - SIN duplicados: la ingestión a ES es idempotente (_id determinista), así que
    si una lectura sale por vivo y por recuperación -> upsert, no duplica.
  - maxQueue NO se toca (2.000.000): la cola acumula lo máximo, sin bloquear el
    vivo.

NO toca el context/cola (~/.node-red/context). Idempotente.

Uso:
    python3 fix_mqtt_twopath.py <flows.json> [--apply|--remove|--check]
"""
import json
import sys
import os

TAB_Z = "9007b3b5e673a329"
GROUP_G = "63cafd50bfd72ec5"
LIMPIA = "fea2ff52f3b4eac4"     # "Limpia msg"  (hoy -> guaranteed-delivery)
GD = "9a8e08df43087b8a"         # guaranteed-delivery ("Send to MQTT")
MQTTOUT = "d74f3c5aeaf1a2a5"    # nodo mqtt out
ROUTER = "tw0pathrouter001"     # switch nuevo (vivo/recuperación)
STATUS = "tw0pathstatus001"     # status del mqtt out
CONN = "tw0pathconn00001"       # function estado conexión

CONN_FUNC = (
    "// Mantiene global.mqttOnline según el estado del nodo 'mqtt out'.\n"
    "// Al pasar de offline->online, empuja un FAIL a la cola de recuperación\n"
    "// para destrabarla y que drene en paralelo (sin frenar el camino en vivo).\n"
    "const online = !!(msg.status && msg.status.fill === 'green');\n"
    "const prev = global.get('mqttOnline');\n"
    "global.set('mqttOnline', online);\n"
    "// Dispara al pasar a online desde NO-online (incluye el primer connect\n"
    "// tras reiniciar, donde prev es undefined): destraba la cola de recuperación.\n"
    "if (online && prev !== true) {\n"
    "    return { control: 'FAIL' };\n"
    "}\n"
    "return null;\n"
)


def router_node():
    return {
        "id": ROUTER, "type": "switch", "z": TAB_Z, "g": GROUP_G,
        "name": "¿MQTT online?", "property": "mqttOnline", "propertyType": "global",
        "rules": [{"t": "true"}, {"t": "else"}],
        "checkall": "false", "repair": False, "outputs": 2,
        "x": 2500, "y": 300, "wires": [[MQTTOUT], [GD]],
    }


def status_node():
    return {
        "id": STATUS, "type": "status", "z": TAB_Z, "g": GROUP_G,
        "name": "estado mqtt out", "scope": [MQTTOUT],
        "x": 2500, "y": 360, "wires": [[CONN]],
    }


def conn_node():
    return {
        "id": CONN, "type": "function", "z": TAB_Z, "g": GROUP_G,
        "name": "Conexión MQTT", "func": CONN_FUNC, "outputs": 1,
        "timeout": 0, "noerr": 0, "initialize": "", "finalize": "", "libs": [],
        "x": 2700, "y": 360, "wires": [[GD]],
    }


def _index(flows):
    return {n["id"]: n for n in flows if isinstance(n, dict) and "id" in n}


def _rewire(flows, from_id, old_target, new_target):
    node = _index(flows).get(from_id)
    if not node or "wires" not in node:
        return
    for port in node["wires"]:
        for i, tgt in enumerate(port):
            if tgt == old_target:
                port[i] = new_target


def _group_add(flows, ids):
    g = _index(flows).get(GROUP_G)
    if g and isinstance(g.get("nodes"), list):
        for i in ids:
            if i not in g["nodes"]:
                g["nodes"].append(i)


def _group_del(flows, ids):
    g = _index(flows).get(GROUP_G)
    if g and isinstance(g.get("nodes"), list):
        g["nodes"] = [i for i in g["nodes"] if i not in ids]


def is_applied(flows):
    return ROUTER in _index(flows)


def cmd_apply(flows):
    idx = _index(flows)
    changed = 0
    # Auto-reparación: si ya está aplicado pero el código del function 'conn'
    # cambió (p.ej. una corrección), actualizarlo en sitio.
    if CONN in idx and idx[CONN].get("func") != CONN_FUNC:
        idx[CONN]["func"] = CONN_FUNC
        changed = 1
    if ROUTER in idx:
        return changed  # ya aplicado (quizá con func recién actualizado)
    # requiere el pipeline de publicación presente
    if not all(k in idx for k in (LIMPIA, GD, MQTTOUT)):
        return changed
    # "Limpia msg" ya no va al guaranteed-delivery, va al router
    _rewire(flows, LIMPIA, GD, ROUTER)
    flows.append(router_node())
    flows.append(status_node())
    flows.append(conn_node())
    _group_add(flows, [ROUTER, STATUS, CONN])
    return 1


def cmd_remove(flows):
    idx = _index(flows)
    if ROUTER not in idx:
        return 0
    # volver: "Limpia msg" -> guaranteed-delivery
    _rewire(flows, LIMPIA, ROUTER, GD)
    flows[:] = [n for n in flows if not (isinstance(n, dict) and n.get("id") in (ROUTER, STATUS, CONN))]
    _group_del(flows, [ROUTER, STATUS, CONN])
    return 1


def load(path):
    if not os.path.exists(path):
        print(f"  [X] No existe: {path}", file=sys.stderr)
        sys.exit(2)
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as e:
        print(f"  [X] No se pudo parsear {path}: {e}", file=sys.stderr)
        sys.exit(2)


def save(path, flows):
    with open(path, "w") as f:
        json.dump(flows, f, indent=4)


def main():
    if len(sys.argv) < 2:
        print(f"Uso: {sys.argv[0]} <flows.json> [--apply|--remove|--check]", file=sys.stderr)
        sys.exit(1)
    path = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) >= 3 else "--apply"

    flows = load(path)
    if not isinstance(flows, list):
        print(f"  [X] Formato inesperado en {path}", file=sys.stderr)
        sys.exit(2)

    if mode == "--check":
        sys.exit(0 if is_applied(flows) else 1)
    elif mode == "--apply":
        cambios = cmd_apply(flows)
        if cambios:
            save(path, flows)
        print(f"applied={cambios}")
    elif mode == "--remove":
        cambios = cmd_remove(flows)
        if cambios:
            save(path, flows)
        print(f"removed={cambios}")
    else:
        print(f"Modo desconocido: {mode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
