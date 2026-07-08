#!/usr/bin/env python3
"""
Parcheador de flows.json — arreglo del envío garantizado por MQTT (jul 2026).

PROBLEMA:
  El lazo de confirmación de "Send to MQTT" empareja los mensajes "sending" y
  "completed" con un `join` de count=2 que los junta POR POSICIÓN, no por id.
  Tras una desconexión (equipo offline con la cola llena), queda un "completed"
  suelto y a partir de ahí el join empareja sending_N con completed_(N-1):
  "Check messages match" ve ids distintos, devuelve null, y el guaranteed-delivery
  nunca recibe OK/FAIL -> se queda clavado en waitingForOKFail -> la cola no se
  vacía nunca aunque el equipo ya tenga conexión.

ARREGLO:
  Sustituye el `join` (83f5f6c485dc4f01) + "Check messages match" (a362e8ab964e53ab)
  por UN function ("Correlar por id") que empareja sending/completed por su id
  (msg.payload.id) usando un mapa en contexto, con purga por TTL. Nunca se
  desincroniza. El guaranteed-delivery sigue recibiendo msg.control = OK/FAIL igual.

  NO toca la cola: solo edita el grafo de nodos (flows.json), no el context store
  (~/.node-red/context). Al reiniciar Node-RED, la cola encolada se envía sola.

Uso:
    python3 fix_mqtt_delivery.py <ruta_a_flows.json> [--apply|--remove|--check]

Modos (idempotente en ambos sentidos):
    --check   exit 0 si el arreglo está aplicado, exit 1 si no.
    --apply   aplica el arreglo (correlar por id).
    --remove  revierte al join + "Check messages match" original.
"""
import json
import sys
import os

# ─── ids de los nodos implicados (el flow es común a toda la flota) ───
JOIN_ID = "83f5f6c485dc4f01"          # join count=2 (a sustituir)
CHECK_ID = "a362e8ab964e53ab"         # "Check messages match" (a sustituir)
CORR_ID = "c0rre1arp0rid0001"         # function nuevo "Correlar por id"
GD_ID = "9a8e08df43087b8a"            # guaranteed-delivery (destino del control)
SENDING_ID = "f3bce0a814a7d420"       # "key: sending, save topic and payload"
COMPLETED_ID = "0c686365bdbdc1df"     # "key: completed, save topic and payload"
TAB_Z = "9007b3b5e673a329"
GROUP_G = "63cafd50bfd72ec5"

# ─── código del function "Correlar por id" ───
CORR_FUNC = (
    "// Correla 'sending' y 'completed' por id (no por posicion).\n"
    "// Sustituye al join + 'Check messages match': evita el desfase que deja\n"
    "// la cola de envio atascada tras una desconexion.\n"
    "const key = msg.key;               // 'sending' | 'completed'\n"
    "const p = msg.payload || {};\n"
    "const id = p.id;\n"
    "if (!key || id == null) return null;\n"
    "\n"
    "const TTL = 60000;                 // descarta medias-parejas > 60 s\n"
    "const now = Date.now();\n"
    "let pending = context.get('pending') || {};\n"
    "\n"
    "for (const k in pending) {\n"
    "    if (now - pending[k].t > TTL) delete pending[k];\n"
    "}\n"
    "\n"
    "let entry = pending[id] || { t: now };\n"
    "entry[key] = { topic: p.topic, data: p.data };\n"
    "entry.t = now;\n"
    "pending[id] = entry;\n"
    "\n"
    "if (entry.sending && entry.completed) {\n"
    "    const s = entry.sending, c = entry.completed;\n"
    "    let equal = false;\n"
    "    if (s.topic === c.topic) {\n"
    "        if (Buffer.isBuffer(s.data)) {\n"
    "            equal = Buffer.isBuffer(c.data) && Buffer.compare(s.data, c.data) === 0;\n"
    "        } else {\n"
    "            equal = (s.data === c.data);\n"
    "        }\n"
    "    }\n"
    "    delete pending[id];\n"
    "    context.set('pending', pending);\n"
    "    return { control: equal ? 'OK' : 'FAIL', id: id };\n"
    "}\n"
    "\n"
    "context.set('pending', pending);\n"
    "return null;\n"
)

# ─── código original de "Check messages match" (para --remove) ───
CHECK_FUNC = (
    "const s = msg.payload.sending;\n"
    "const c = msg.payload.completed;\n"
    "\n"
    "if (!s || !c) return null;\n"
    "\n"
    "if (s.id !== c.id) return null;\n"
    "\n"
    "let equal = false;\n"
    "\n"
    "if (s.topic === c.topic) {\n"
    "    if (Buffer.isBuffer(s.data)) {\n"
    "        equal = Buffer.isBuffer(c.data) && Buffer.compare(s.data, c.data) === 0;\n"
    "    } else {\n"
    "        equal = (s.data === c.data);\n"
    "    }\n"
    "}\n"
    "\n"
    "msg.control = equal ? \"OK\" : \"FAIL\";\n"
    "return msg;"
)


def corr_node():
    return {
        "id": CORR_ID, "type": "function", "z": TAB_Z, "g": GROUP_G,
        "name": "Correlar por id (OK/FAIL)", "func": CORR_FUNC,
        "outputs": 1, "timeout": 0, "noerr": 0, "initialize": "", "finalize": "",
        "libs": [], "x": 3390, "y": 140, "wires": [[GD_ID]],
    }


def join_node():
    return {
        "id": JOIN_ID, "type": "join", "z": TAB_Z, "g": GROUP_G, "name": "",
        "mode": "custom", "build": "object", "property": "payload",
        "propertyType": "msg", "key": "key", "joiner": "\\n", "joinerType": "str",
        "useparts": False, "accumulate": False, "timeout": "", "count": "2",
        "reduceRight": False, "reduceExp": "", "reduceInit": "",
        "reduceInitType": "", "reduceFixup": "", "x": 3190, "y": 140,
        "wires": [[CHECK_ID]],
    }


def check_node():
    return {
        "id": CHECK_ID, "type": "function", "z": TAB_Z, "g": GROUP_G,
        "name": "Check messages match", "func": CHECK_FUNC, "outputs": 1,
        "timeout": 0, "noerr": 0, "initialize": "", "finalize": "", "libs": [],
        "x": 3390, "y": 140, "wires": [[GD_ID]],
    }


def _index(flows):
    return {n["id"]: n for n in flows if isinstance(n, dict) and "id" in n}


def _rewire(flows, from_id, old_target, new_target):
    """Reemplaza old_target por new_target en las wires del nodo from_id."""
    node = _index(flows).get(from_id)
    if not node or "wires" not in node:
        return
    for port in node["wires"]:
        for i, tgt in enumerate(port):
            if tgt == old_target:
                port[i] = new_target


def is_applied(flows):
    return CORR_ID in _index(flows)


def cmd_apply(flows):
    idx = _index(flows)
    if CORR_ID in idx:
        return 0  # ya aplicado
    # el flow debe tener el guaranteed-delivery y los dos "key:" para que tenga sentido
    if GD_ID not in idx or SENDING_ID not in idx or COMPLETED_ID not in idx:
        return 0
    # 1) rewire sending/completed: join -> correlate
    _rewire(flows, SENDING_ID, JOIN_ID, CORR_ID)
    _rewire(flows, COMPLETED_ID, JOIN_ID, CORR_ID)
    # 2) quitar join + check
    flows[:] = [n for n in flows if not (isinstance(n, dict) and n.get("id") in (JOIN_ID, CHECK_ID))]
    # 3) insertar el correlate
    flows.append(corr_node())
    return 1


def cmd_remove(flows):
    idx = _index(flows)
    if CORR_ID not in idx:
        return 0  # nada que revertir
    # 1) rewire sending/completed: correlate -> join
    _rewire(flows, SENDING_ID, CORR_ID, JOIN_ID)
    _rewire(flows, COMPLETED_ID, CORR_ID, JOIN_ID)
    # 2) quitar el correlate
    flows[:] = [n for n in flows if not (isinstance(n, dict) and n.get("id") == CORR_ID)]
    # 3) restaurar join + check (si no estuvieran)
    if JOIN_ID not in _index(flows):
        flows.append(join_node())
    if CHECK_ID not in _index(flows):
        flows.append(check_node())
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
