#!/usr/bin/env python3
"""
Parcheador de flows.json — arregla el botón "Borrar cola de envío" (jul 2026).

ANTES: el botón (nodo exec 7db682f32057d9b9) NO borraba nada; hacía
    sudo systemctl stop kiosk.service && DISPLAY=:0 pcmanfm <context> && sudo systemctl stop nodered
es decir, abría un explorador de archivos gráfico para borrar A MANO y paraba
nodered. Por sesión remota no se ve el explorador -> "no hace nada".

AHORA: borra el context del nodo de envío (guaranteed-delivery 9a8e08df43087b8a
= la cola) y reinicia nodered, de forma limpia. NO toca el resto de variables
(globales, config del equipo, histórico…), solo la cola de ese nodo.

Uso: python3 fix_borrar_cola.py <flows.json> [--apply|--remove|--check]
"""
import json
import sys
import os

EXEC_ID = "7db682f32057d9b9"          # nodo exec "Borrado" del botón
GD_ID = "9a8e08df43087b8a"            # guaranteed-delivery (su context = la cola)
CONTEXT_DIR = "/home/gesinne/.node-red/context"

NEW_CMD = f"sudo rm -rf {CONTEXT_DIR}/{GD_ID} && sudo systemctl restart nodered"
OLD_CMD = f"sudo systemctl stop kiosk.service && DISPLAY=:0 pcmanfm {CONTEXT_DIR} && sudo systemctl stop nodered"


def _index(flows):
    return {n["id"]: n for n in flows if isinstance(n, dict) and "id" in n}


def is_applied(flows):
    n = _index(flows).get(EXEC_ID)
    return bool(n and n.get("command") == NEW_CMD)


def cmd_apply(flows):
    n = _index(flows).get(EXEC_ID)
    if not n or n.get("type") != "exec":
        return 0
    if n.get("command") == NEW_CMD:
        return 0
    n["command"] = NEW_CMD
    return 1


def cmd_remove(flows):
    n = _index(flows).get(EXEC_ID)
    if not n or n.get("command") != NEW_CMD:
        return 0
    n["command"] = OLD_CMD
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
        c = cmd_apply(flows)
        if c:
            save(path, flows)
        print(f"applied={c}")
    elif mode == "--remove":
        c = cmd_remove(flows)
        if c:
            save(path, flows)
        print(f"removed={c}")
    else:
        print(f"Modo desconocido: {mode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
