#!/usr/bin/env python3
"""
Parcheador silencioso de flows.json para Node-RED.

Modifica:
1) Nodos TensionInicialL{1,2,3} y EstadoInicialL{1,2,3}: solo escriben
   FLASH si el valor cambia. Evita escrituras redundantes.

2) Nodo "Modbus Queue": garantiza 30ms de silencio entre frames Modbus.
   Reduce la probabilidad de buffer overflow en el DSP.

Sin comentarios visibles. Idempotencia detectada por presencia de
variables internas (__bus_lastMS, _lastTension..., _lastEstado...).

Uso:
    python3 patch_flow.py <ruta_a_flows.json>
"""
import json
import sys
import re
import os


def patch_inicial_node(node):
    """Aplica deduplicacion a TensionInicialL{1,2,3} o EstadoInicialL{1,2,3}."""
    name = node.get("name", "")
    func_actual = node.get("func", "")

    match = re.search(r"L(\d)$", name)
    if not match:
        return False
    fase = match.group(1)

    if name.startswith("TensionInicialL"):
        var_global = "consigna"
        last_var = f"_lastTensionInicialL{fase}"
        addr = 56
    elif name.startswith("EstadoInicialL"):
        var_global = "estadoinicial"
        last_var = f"_lastEstadoInicialL{fase}"
        addr = 55
    else:
        return False

    # Idempotencia: detectar por presencia de la variable interna
    if last_var in func_actual:
        return False

    nuevo_func = (
        f'var nuevoValor = global.get("{var_global}");\n'
        f'var ultimoValor = global.get("{last_var}");\n'
        f'if (nuevoValor === ultimoValor) {{ return null; }}\n'
        f'global.set("{last_var}", nuevoValor);\n'
        f'\n'
        f'msg.payload = {{\n'
        f'    value: nuevoValor,\n'
        f"    'fc': 6,\n"
        f"    'unitid': {fase},\n"
        f"    'address': {addr},\n"
        f"    'quantity': 1\n"
        f'}};\n'
        f'msg.topic = "{name}";\n'
        f'return msg;\n'
    )
    node["func"] = nuevo_func
    return True


def patch_modbus_queue(node):
    """Anade silencio de 30ms al Modbus Queue."""
    if node.get("name", "") != "Modbus Queue":
        return False

    func_actual = node.get("func", "")

    # Idempotencia: detectar por presencia de la variable interna
    if "__bus_lastMS" in func_actual:
        return False

    # --- Variante refactorizada (usa sendNextCommand) ---
    if "function sendNextCommand()" in func_actual:
        nueva_funcion = '''function sendNextCommand() {
    if (queue.length === 0) return;
    var __nowMS = Date.now();
    var __bus_lastMS = context.get("__bus_lastMS") || 0;
    var __MIN_GAP = 30;
    var __dt = __nowMS - __bus_lastMS;

    let newmsg = queue.shift();
    contextData.sent = true;
    contextData.lastmsg = newmsg;
    contextData.queue = queue;
    let isRead = CONFIG.readFCs.includes(newmsg.payload.fc);
    let outputIndex = isRead && OUTPUT_MAP[newmsg.payload.unitid] !== undefined ? OUTPUT_MAP[newmsg.payload.unitid] : 1;

    if (__dt < __MIN_GAP) {
        var __espera = __MIN_GAP - __dt;
        var __outDelay = [null, null, null, null, null];
        __outDelay[outputIndex] = newmsg;
        setTimeout(function(){
            node.send(__outDelay);
            context.set("__bus_lastMS", Date.now());
        }, __espera);
        updateStatus("yellow", "ring", "Delayed " + __espera + "ms");
        return;
    }

    context.set("__bus_lastMS", __nowMS);
    outputs[outputIndex] = newmsg;
    updateStatus("green", "dot", isRead ? (OUTPUT_MAP[newmsg.payload.unitid] ? `Read L${newmsg.payload.unitid} sent!` : `Read sent!`) : "Write sent!");
}'''

        match = re.search(
            r'function sendNextCommand\(\) \{[^}]*(?:\{[^}]*\}[^}]*)*\}',
            func_actual,
            re.DOTALL
        )
        if not match:
            return False
        nuevo_func = (
            func_actual[:match.start()] + nueva_funcion + func_actual[match.end():]
        )
        node["func"] = nuevo_func
        return True

    # --- Variante clasica (usa "if (send) {") ---
    if "if (send) {" in func_actual:
        header = (
            'var __nowMS = new Date().getTime();\n'
            'var __bus_lastMS = context.get("__bus_lastMS") || 0;\n'
            'var __MIN_GAP = 30;\n'
            '\n'
        )
        nueva_seccion = (
            'if (send) {\n'
            '    if (__nowMS - __bus_lastMS < __MIN_GAP) { return null; }\n'
            '    context.set("__bus_lastMS", __nowMS);\n'
        )
        nuevo_func = header + func_actual.replace("if (send) {", nueva_seccion, 1)
        node["func"] = nuevo_func
        return True

    return False


def main():
    if len(sys.argv) != 2:
        print(f"Uso: {sys.argv[0]} <ruta_a_flows.json>", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]
    if not os.path.exists(path):
        print(f"  [X] No existe: {path}", file=sys.stderr)
        sys.exit(1)

    try:
        with open(path) as f:
            flows = json.load(f)
    except Exception as e:
        print(f"  [X] No se pudo parsear {path}: {e}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(flows, list):
        print(f"  [X] Formato inesperado en {path}", file=sys.stderr)
        sys.exit(1)

    flash_n = 0
    modbus = False

    for node in flows:
        if not isinstance(node, dict):
            continue
        if node.get("type") != "function":
            continue

        name = node.get("name", "")

        if name.startswith("TensionInicialL") or name.startswith("EstadoInicialL"):
            if patch_inicial_node(node):
                flash_n += 1
        elif name == "Modbus Queue":
            if patch_modbus_queue(node):
                modbus = True

    if flash_n > 0 or modbus:
        with open(path, "w") as f:
            json.dump(flows, f, indent=4)


if __name__ == "__main__":
    main()
