#!/usr/bin/env python3
"""
Parcheador de flows.json — opcional desde 2026-05-05.

Cosas que aplica/quita:
  1) commandDelay del modbus-client a 50ms (solo cambio de config; siempre se
     aplica, no afecta a los nodos function).
  2) Deduplicacion en TensionInicialL{1,2,3} y EstadoInicialL{1,2,3}:
     solo escribe FLASH si el valor cambia. Esto es OPCIONAL y se controla
     por argumento.

Uso:
    python3 patch_flow.py <ruta_a_flows.json> [--apply|--remove|--check]

Sin argumento de modo:
  - Comportamiento histórico: aplicar (silencioso). Mantenido por compatibilidad
    pero `actualizar_flow.sh` ahora siempre pasa --apply o --remove explícito.

Modos:
  --check   Sale con exit 0 si el patch dedup está aplicado, exit 1 si no
            (commandDelay se ignora a efectos de check).
  --apply   Aplica commandDelay y dedup.
  --remove  Revierte la dedup a la version "limpia" (mantiene commandDelay).

Idempotente en ambos sentidos.
"""
import json
import sys
import re
import os

MIN_CMD_DELAY = 50  # milliseconds


# ─── Marcadores que indican que un nodo está parcheado ───
def is_node_patched(node):
    name = node.get("name", "")
    func = node.get("func", "")
    if not (name.startswith("TensionInicialL") or name.startswith("EstadoInicialL")):
        return False
    return ("_lastTIL" in func) or ("_lastEIL" in func)


def clean_func_for(name):
    """Devuelve la función "limpia" (sin dedup) tal y como viene del repo."""
    m = re.search(r"L(\d)$", name)
    if not m:
        return None
    fase = m.group(1)
    if name.startswith("TensionInicialL"):
        return (
            f"var inicial = global.get('inicial');\n"
            f"msg.payload = {{\n"
            f"    value: inicial,\n"
            f"    'fc': 6,\n"
            f"    'unitid': {fase},\n"
            f"    'address': 56,\n"
            f"    'quantity': 1\n"
            f"}}\n"
            f"msg.topic = \"TensionInicial L{fase}\"\n"
            f"return msg;"
        )
    if name.startswith("EstadoInicialL"):
        return (
            f"var estadoinicial = global.get('estadoinicial');\n\n"
            f"msg.payload = {{\n"
            f"    value: estadoinicial,\n"
            f"    'fc': 6,\n"
            f"    'unitid': {fase},\n"
            f"    'address': 55,\n"
            f"    'quantity': 1\n"
            f"}}\n"
            f"msg.topic = \"EstadoInicialL{fase}\"\n"
            f"return msg;"
        )
    return None


# ─── PATCH (aplicar dedup) ───
def patch_inicial_node(node):
    name = node.get("name", "")
    func_actual = node.get("func", "")
    match = re.search(r"L(\d)$", name)
    if not match:
        return False
    fase = match.group(1)

    if name.startswith("TensionInicialL"):
        var_global = "inicial"
        last_var = f"_lastTIL{fase}"
        addr = 56
    elif name.startswith("EstadoInicialL"):
        var_global = "estadoinicial"
        last_var = f"_lastEIL{fase}"
        addr = 55
    else:
        return False

    if last_var in func_actual:
        return False  # ya está parcheado

    node["func"] = (
        f'var v = global.get("{var_global}");\n'
        f'if (v === global.get("{last_var}")) return null;\n'
        f'global.set("{last_var}", v);\n'
        f'msg.payload = {{ value: v, "fc": 6, "unitid": {fase}, "address": {addr}, "quantity": 1 }};\n'
        f'msg.topic = "{name}";\n'
        f'return msg;\n'
    )
    return True


# ─── UNPATCH (revertir dedup) ───
def unpatch_inicial_node(node):
    name = node.get("name", "")
    if not is_node_patched(node):
        return False
    clean = clean_func_for(name)
    if clean is None:
        return False
    node["func"] = clean
    return True


def patch_modbus_client(node):
    if node.get("type", "") != "modbus-client":
        return False
    try:
        actual_ms = int(node.get("commandDelay", "") or -1)
    except (ValueError, TypeError):
        actual_ms = -1
    if actual_ms == MIN_CMD_DELAY:
        return False
    node["commandDelay"] = MIN_CMD_DELAY
    return True


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


def cmd_check(flows):
    for node in flows:
        if isinstance(node, dict) and is_node_patched(node):
            return True
    return False


def cmd_apply(flows):
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
    return cambios


def cmd_remove(flows):
    cambios = 0
    for node in flows:
        if not isinstance(node, dict):
            continue
        if node.get("type") == "function" and unpatch_inicial_node(node):
            cambios += 1
    return cambios


def main():
    if len(sys.argv) < 2:
        print(f"Uso: {sys.argv[0]} <flows.json> [--apply|--remove|--check]", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) >= 3 else "--apply"  # compat: sin modo = apply

    flows = load(path)
    if not isinstance(flows, list):
        print(f"  [X] Formato inesperado en {path}", file=sys.stderr)
        sys.exit(2)

    if mode == "--check":
        # exit 0 si está parcheado, 1 si no
        sys.exit(0 if cmd_check(flows) else 1)
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
