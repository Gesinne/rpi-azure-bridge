#!/usr/bin/env python3
"""
Parcheador de flows.json: telemetría comprimida sin pérdida (nov 2026).

PROBLEMA:
  Cada equipo manda ~4,6 mensajes MQTT por segundo (uno por fase y lectura) y
  gasta ~4,3 GB/mes de la SIM solo en telemetría (medido en el broker el
  23-nov-2026). Las SIM son de 4 GB.

ARREGLO:
  Inserta un function "Comprimir lote 1 s" entre el link in "Send to MQTT" y
  "Limpia msg". Junta las lecturas de las tres fases durante 1 segundo y las
  manda en UN mensaje comprimido (deflate raw) al topic Ez/<serie>. Cada línea
  del lote es "<fase>:<csv>" con el CSV intacto.
  En el servidor, el relé ez-relay (/apps/mqtt/ez-relay) lo descomprime y
  publica cada línea en Equipo/L<fase> exactamente igual que antes: mismos
  campos, misma cadencia, mismo Elastic. Único coste: hasta 1 s de retraso.
  Medido sobre mensajes reales: ~4x menos datos de subida.

  No toca la cola de entrega garantizada ni su contenido: lo que ya estuviera
  encolado sale sin comprimir y el servidor lo acepta igual.

  Necesita functionExternalModules activo en settings.js (para usar zlib en el
  function). Si no lo está, no aplica nada.

Uso:
    python3 comprimir_mqtt.py <flows.json> [--apply|--remove|--check] [--settings <settings.js>]

Modos (idempotente):
    --check   exit 0 si está aplicado, exit 1 si no.
    --apply   aplica (por defecto).
    --remove  lo quita y deja el flow como estaba.
"""
import json
import os
import re
import sys

COMP_ID = "c0mpr1m1r10te001"
COMP_NAME = "Comprimir lote 1 s"

COMP_INIT = (
    "// Cada segundo manda el lote acumulado, comprimido sin pérdida, a Ez/<serie>.\n"
    "// En el servidor, ez-relay lo descomprime y publica cada línea en Equipo/Lx.\n"
    "setInterval(function () {\n"
    "    const lote = context.get('lote') || [];\n"
    "    if (!lote.length) return;\n"
    "    context.set('lote', []);\n"
    "    const serie = lote[0].split(',')[1] || 'x';\n"
    "    const texto = Buffer.from(lote.join('\\n'), 'utf8');\n"
    "    const z = zlib.deflateRawSync(texto, { level: 9 });\n"
    "    node.status({ fill: 'green', shape: 'dot', text: lote.length + ' lecturas, ' + texto.length + ' -> ' + z.length + ' B' });\n"
    "    node.send({ topic: 'Ez/' + serie, payload: z });\n"
    "}, 1000);\n"
)

COMP_FUNC = (
    "// Junta las lecturas de las tres fases durante 1 s (el envío está en On Start).\n"
    "// Lo que no sea telemetría Equipo/Lx en texto pasa tal cual.\n"
    "const t = msg.topic || '';\n"
    "if (!/^Equipo\\/L[123]$/.test(t) || typeof msg.payload !== 'string' || msg.payload.indexOf('\\n') >= 0) return msg;\n"
    "const lote = context.get('lote') || [];\n"
    "lote.push(t.slice(-1) + ':' + msg.payload);\n"
    "if (lote.length > 600) lote.splice(0, lote.length - 600);  // tope si el temporizador se parase\n"
    "context.set('lote', lote);\n"
    "return null;\n"
)


def _index(flows):
    return {n["id"]: n for n in flows if isinstance(n, dict) and "id" in n}


def find_nodes(flows):
    """Localiza link in 'Send to MQTT' y 'Limpia msg' por estructura, no por id."""
    idx = _index(flows)
    for li in flows:
        if not (isinstance(li, dict) and li.get("type") == "link in" and li.get("name") == "Send to MQTT"):
            continue
        for port in li.get("wires", []):
            for tgt in port:
                n = idx.get(tgt)
                if n and n.get("type") == "function" and n.get("name") == "Limpia msg":
                    return li, n
                if n and n.get("id") == COMP_ID:
                    # ya aplicado: Limpia msg es el destino del compresor
                    for p2 in n.get("wires", []):
                        for t2 in p2:
                            n2 = idx.get(t2)
                            if n2 and n2.get("name") == "Limpia msg":
                                return li, n2
    return None, None


def is_applied(flows):
    return COMP_ID in _index(flows)


def comp_node(li, limpia):
    return {
        "id": COMP_ID, "type": "function", "z": li.get("z"), "name": COMP_NAME,
        "func": COMP_FUNC, "outputs": 1, "timeout": 0, "noerr": 0,
        "initialize": COMP_INIT, "finalize": "",
        "libs": [{"var": "zlib", "module": "zlib"}],
        "x": (li.get("x", 0) + limpia.get("x", 0)) // 2, "y": li.get("y", 0) + 40,
        "wires": [[limpia["id"]]],
        **({"g": li["g"]} if li.get("g") else {}),
    }


def external_modules_ok(settings_path):
    if not settings_path:
        return True
    try:
        txt = open(settings_path).read()
    except OSError:
        print(f"  [X] No se puede leer {settings_path}", file=sys.stderr)
        return False
    for line in txt.splitlines():
        s = line.strip()
        if s.startswith("//"):
            continue
        m = re.match(r"functionExternalModules\s*:\s*(\w+)", s)
        if m:
            return m.group(1) == "true"
    return False


def cmd_apply(flows):
    if is_applied(flows):
        return 0
    li, limpia = find_nodes(flows)
    if not li:
        print("  [X] No encuentro 'Send to MQTT' -> 'Limpia msg' en este flow", file=sys.stderr)
        sys.exit(3)
    for port in li["wires"]:
        for i, tgt in enumerate(port):
            if tgt == limpia["id"]:
                port[i] = COMP_ID
    flows.append(comp_node(li, limpia))
    return 1


def cmd_remove(flows):
    if not is_applied(flows):
        return 0
    li, limpia = find_nodes(flows)
    if li and limpia:
        for port in li["wires"]:
            for i, tgt in enumerate(port):
                if tgt == COMP_ID:
                    port[i] = limpia["id"]
    flows[:] = [n for n in flows if not (isinstance(n, dict) and n.get("id") == COMP_ID)]
    return 1


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    path = args[0]
    mode = next((a for a in args[1:] if a in ("--apply", "--remove", "--check")), "--apply")
    settings = None
    if "--settings" in args:
        settings = args[args.index("--settings") + 1]
    elif os.path.exists(os.path.join(os.path.dirname(os.path.abspath(path)), "settings.js")):
        settings = os.path.join(os.path.dirname(os.path.abspath(path)), "settings.js")

    with open(path) as f:
        flows = json.load(f)

    if mode == "--check":
        sys.exit(0 if is_applied(flows) else 1)
    if mode == "--apply":
        if not external_modules_ok(settings):
            print("  [X] functionExternalModules no está a true en settings.js: no aplico nada", file=sys.stderr)
            sys.exit(4)
        cambios = cmd_apply(flows)
    else:
        cambios = cmd_remove(flows)
    if cambios:
        with open(path, "w") as f:
            json.dump(flows, f, indent=4)
    print(("applied=" if mode == "--apply" else "removed=") + str(cambios))


if __name__ == "__main__":
    main()
