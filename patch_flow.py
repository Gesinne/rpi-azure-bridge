#!/usr/bin/env python3
"""
Parcheador silencioso de flows.json.

1) Sube commandDelay del modbus-client a 100ms (solo cambio de config,
   no toca codigo de funciones). Garantiza silencio entre frames Modbus.

2) Anade deduplicacion en TensionInicialL{1,2,3} y EstadoInicialL{1,2,3}:
   solo escribe FLASH si el valor cambia (3 lineas extras minimas).

Uso:
    python3 patch_flow.py <ruta_a_flows.json>

Idempotente.
"""
import json
import sys
import re
import os

MIN_CMD_DELAY = 50  # milliseconds (suficiente para silencio Modbus RTU)


def patch_inicial_node(node):
    """Anade deduplicacion a TensionInicialL{1,2,3} o EstadoInicialL{1,2,3}."""
    name = node.get("name", "")
    func_actual = node.get("func", "")

    match = re.search(r"L(\d)$", name)
    if not match:
        return False
    fase = match.group(1)

    if name.startswith("TensionInicialL"):
        var_global = "consigna"
        last_var = f"_lastTIL{fase}"
        addr = 56
    elif name.startswith("EstadoInicialL"):
        var_global = "estadoinicial"
        last_var = f"_lastEIL{fase}"
        addr = 55
    else:
        return False

    if last_var in func_actual:
        return False  # Idempotencia

    nuevo_func = (
        f'var v = global.get("{var_global}");\n'
        f'if (v === global.get("{last_var}")) return null;\n'
        f'global.set("{last_var}", v);\n'
        f'msg.payload = {{ value: v, "fc": 6, "unitid": {fase}, "address": {addr}, "quantity": 1 }};\n'
        f'msg.topic = "{name}";\n'
        f'return msg;\n'
    )
    node["func"] = nuevo_func
    return True


def patch_modbus_client(node):
    """Sube commandDelay del modbus-client al menos a MIN_CMD_DELAY ms."""
    if node.get("type", "") != "modbus-client":
        return False

    actual = node.get("commandDelay", "")
    try:
        actual_ms = int(actual)
    except (ValueError, TypeError):
        actual_ms = 0

    if actual_ms >= MIN_CMD_DELAY:
        return False  # Ya tiene un delay >= MIN_CMD_DELAY

    node["commandDelay"] = MIN_CMD_DELAY
    return True


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

    cambios = 0

    for node in flows:
        if not isinstance(node, dict):
            continue

        ntype = node.get("type", "")
        nname = node.get("name", "")

        if ntype == "function" and (nname.startswith("TensionInicialL") or nname.startswith("EstadoInicialL")):
            if patch_inicial_node(node):
                cambios += 1
        elif ntype == "modbus-client":
            if patch_modbus_client(node):
                cambios += 1

    if cambios > 0:
        with open(path, "w") as f:
            json.dump(flows, f, indent=4)


if __name__ == "__main__":
    main()
