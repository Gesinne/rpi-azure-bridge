#!/usr/bin/env python3
"""
Parcheador silencioso de flows.json para Node-RED.

Aplica dos patches sobre el flow:

1) FLASH_PATCH_v1: nodos TensionInicialL{1,2,3} y EstadoInicialL{1,2,3}
   solo escriben FLASH si el valor cambia. Evita escrituras redundantes
   que desgastan el sector FLASH del MC56F84789.

2) MODBUS_PATCH_v1: el nodo "Modbus Queue" se modifica para garantizar
   un silencio minimo entre frames Modbus (30ms) y un drenaje del bus
   tras timeouts. Reduce la probabilidad de que el firmware procese
   frames concatenados (causa de buffer overflow en el DSP).

Uso:
    python3 patch_flow.py <ruta_a_flows.json>

Idempotente: ejecutar varias veces no rompe nada.
"""
import json
import sys
import re
import os

FLASH_MARKER = "// FLASH_PATCH_v1"
MODBUS_MARKER = "// MODBUS_PATCH_v1"


def patch_inicial_node(node):
    """Aplica FLASH_PATCH_v1 a TensionInicialL{1,2,3} o EstadoInicialL{1,2,3}."""
    name = node.get("name", "")
    func_actual = node.get("func", "")

    if FLASH_MARKER in func_actual:
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
        f'{FLASH_MARKER} - evita escrituras FLASH redundantes\n'
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
    """Aplica MODBUS_PATCH_v1 al nodo function 'Modbus Queue'.

    Soporta dos versiones del flow:
    - Clasica: usa `if (send) {` para enviar
    - Refactorizada: usa `function sendNextCommand()` para enviar

    En ambos casos garantiza un silencio minimo de 30ms entre frames Modbus
    para evitar buffer overflow en el DSP del MC56F84789.
    """
    if node.get("name", "") != "Modbus Queue":
        return False

    func_actual = node.get("func", "")
    if MODBUS_MARKER in func_actual:
        return False

    # --- Variante refactorizada (usa sendNextCommand) ---
    if "function sendNextCommand()" in func_actual:
        # Insertamos al principio del cuerpo de sendNextCommand un check de silencio.
        # Si la ultima TX fue hace menos de 30ms, programamos reinyeccion via setTimeout
        # con node.receive({topic:"next"}) y salimos sin tocar outputs.
        marker_func = "function sendNextCommand() {"
        if marker_func not in func_actual:
            return False
        cabeza = (
            'function sendNextCommand() {\n'
            '    // MODBUS_PATCH_v1: silencio entre frames Modbus (anti-overflow buffer DSP)\n'
            '    var __nowMS = Date.now();\n'
            '    var __lastTxMS = context.get("__patch_lastTxMS") || 0;\n'
            '    var __MIN_GAP_MS = 30;\n'
            '    if (queue.length > 0 && (__nowMS - __lastTxMS) < __MIN_GAP_MS) {\n'
            '        var __espera = __MIN_GAP_MS - (__nowMS - __lastTxMS);\n'
            '        setTimeout(function(){ node.receive({topic:"next", payload:{}}); }, __espera);\n'
            '        return;\n'
            '    }\n'
            '    context.set("__patch_lastTxMS", __nowMS);\n'
        )
        nuevo_func = (
            f'{MODBUS_MARKER} - silencio 30ms entre frames Modbus (variante refactorizada)\n'
            + func_actual.replace(marker_func, cabeza, 1)
        )
        node["func"] = nuevo_func
        return True

    # --- Variante clasica (usa "if (send) {") ---
    if "if (send) {" in func_actual:
        header = (
            f'{MODBUS_MARKER} - silencio 30ms entre frames Modbus (variante clasica)\n'
            f'var __nowMS = new Date().getTime();\n'
            f'var __lastTxMS = context.get("__patch_lastTxMS") || 0;\n'
            f'var __MIN_GAP_MS = 30;\n'
            f'\n'
        )
        nueva_seccion = (
            'if (send) {\n'
            '    var __dt = __nowMS - __lastTxMS;\n'
            '    if (__dt < __MIN_GAP_MS) {\n'
            '        var __espera = __MIN_GAP_MS - __dt;\n'
            '        var __copy = msg;\n'
            '        setTimeout(function(){ node.receive(__copy); }, __espera);\n'
            '        return null;\n'
            '    }\n'
            '    context.set("__patch_lastTxMS", __nowMS);\n'
        )
        nuevo_func = header + func_actual.replace("if (send) {", nueva_seccion, 1)
        node["func"] = nuevo_func
        return True

    # Ninguna variante reconocida
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

    flash_parcheados = 0
    flash_candidatos = 0
    modbus_parcheado = False

    for node in flows:
        if not isinstance(node, dict):
            continue
        if node.get("type") != "function":
            continue

        name = node.get("name", "")

        if name.startswith("TensionInicialL") or name.startswith("EstadoInicialL"):
            flash_candidatos += 1
            if patch_inicial_node(node):
                flash_parcheados += 1
        elif name == "Modbus Queue":
            if patch_modbus_queue(node):
                modbus_parcheado = True

    cambios = flash_parcheados > 0 or modbus_parcheado

    if cambios:
        with open(path, "w") as f:
            json.dump(flows, f, indent=4)

    if flash_parcheados:
        print(f"  [OK] FLASH_PATCH_v1: {flash_parcheados}/{flash_candidatos} nodos")
    elif flash_candidatos:
        print(f"  [OK] FLASH_PATCH_v1 ya aplicado ({flash_candidatos} nodos)")

    if modbus_parcheado:
        print(f"  [OK] MODBUS_PATCH_v1: aplicado a Modbus Queue")
    else:
        print(f"  [OK] MODBUS_PATCH_v1 ya aplicado o no encontrado")


if __name__ == "__main__":
    main()
