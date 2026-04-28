#!/usr/bin/env python3
"""
Parcheador de flows.json para Node-RED.

Modifica los nodos TensionInicialL{1,2,3} y EstadoInicialL{1,2,3} para que
SOLO escriban en FLASH si el valor cambia, evitando escrituras redundantes
que causan desparametrizacion por desgaste de FLASH en el MC56F84789.

Uso:
    python3 patch_flow.py <ruta_a_flows.json>

Es seguro ejecutarlo varias veces: detecta si el flow ya esta parcheado
y no hace nada si es el caso (idempotente).
"""
import json
import sys
import re
import os

PATCH_MARKER = "// FLASH_PATCH_v1"


def patch_node(node):
    """Aplica el parche a un nodo TensionInicialL{1,2,3} o EstadoInicialL{1,2,3}."""
    name = node.get("name", "")
    func_actual = node.get("func", "")

    # Idempotencia: si ya esta parcheado no toca nada
    if PATCH_MARKER in func_actual:
        return False

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

    nuevo_func = (
        f'{PATCH_MARKER} - evita escrituras FLASH redundantes\n'
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

    parcheados = 0
    candidatos = 0
    for node in flows:
        if not isinstance(node, dict):
            continue
        if node.get("type") != "function":
            continue
        name = node.get("name", "")
        if not (name.startswith("TensionInicialL") or name.startswith("EstadoInicialL")):
            continue
        candidatos += 1
        if patch_node(node):
            parcheados += 1

    if parcheados == 0:
        if candidatos > 0:
            print(f"  [OK] flows.json ya esta parcheado ({candidatos} nodos verificados)")
        else:
            print(f"  [!] No se encontraron nodos TensionInicialLx ni EstadoInicialLx")
        sys.exit(0)

    with open(path, "w") as f:
        json.dump(flows, f, indent=4)
    print(f"  [OK] Parcheado FLASH: {parcheados}/{candidatos} nodos modificados")


if __name__ == "__main__":
    main()
