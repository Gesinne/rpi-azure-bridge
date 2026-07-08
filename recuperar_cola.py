#!/usr/bin/env python3
"""
Recupera la cola atascada del guaranteed-delivery ("Send to MQTT") y la republica
al broker MQTT, saltándose el nodo que no drena. Idempotente en ES (no duplica).

Lee el context del nodo (9a8e08df43087b8a/flow.json), extrae la cola (stat.queue)
y publica cada mensaje con su topic/payload usando mosquitto_pub -l (en bloque por
topic, rápido). NO borra nada: tras verificar en Elastic, la cola se vacía con el
botón "Borrar cola de envío".

Uso:
    python3 recuperar_cola.py [ruta_flow.json] [--dry] [--host H] [--port P]
    --dry   solo cuenta (no publica)

Si da MemoryError (Pi con poca RAM), para Node-RED antes:
    sudo systemctl stop nodered
    python3 recuperar_cola.py
    sudo systemctl start nodered
"""
import json
import re
import sys
import os
import shutil
import subprocess
from collections import defaultdict

CTX_DEFAULT = os.path.expanduser("~/.node-red/context/9a8e08df43087b8a/flow.json")
HOST = "57.129.130.106"
PORT = "1883"


def read_creds(user_ov, pass_ov):
    """Lee MQTT_USER/MQTT_PASS de fix_mqtt_credentials.sh (junto al script o en el
    repo del bridge) para autenticar contra el broker sin teclear nada."""
    if user_ov and pass_ov:
        return user_ov, pass_ov
    here = os.path.dirname(os.path.abspath(__file__))
    cands = [here, "/opt/rpi-azure-bridge",
             os.path.expanduser("~/rpi-azure-bridge"),
             "/home/gesinne/rpi-azure-bridge", "/home/pi/rpi-azure-bridge"]
    for d in cands:
        f = os.path.join(d, "fix_mqtt_credentials.sh")
        if os.path.exists(f):
            txt = open(f, errors="ignore").read()
            mu = re.search(r'MQTT_USER\s*=\s*"([^"]*)"', txt)
            mp = re.search(r'MQTT_PASS\s*=\s*"([^"]*)"', txt)
            if mu and mp:
                return user_ov or mu.group(1), pass_ov or mp.group(1)
    return user_ov, pass_ov


def find_queue(obj):
    """Busca recursivamente la primera lista bajo una clave 'queue'."""
    if isinstance(obj, dict):
        q = obj.get("queue")
        if isinstance(q, list):
            return q
        for v in obj.values():
            r = find_queue(v)
            if r is not None:
                return r
    return None


def arg(name, default):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


def main():
    path = CTX_DEFAULT
    for a in sys.argv[1:]:
        if not a.startswith("--") and a.endswith(".json"):
            path = a
    dry = "--dry" in sys.argv
    host = arg("--host", HOST)
    port = arg("--port", PORT)
    user, pw = read_creds(arg("--user", None), arg("--pass", None))
    if not (user and pw):
        print("[!] Sin credenciales MQTT (no encontré fix_mqtt_credentials.sh). "
              "Pásalas con --user U --pass P si el broker las pide.")

    if not os.path.exists(path):
        print(f"[X] No existe {path}")
        sys.exit(1)

    size_mb = os.path.getsize(path) // (1024 * 1024)
    # snapshot estable en el mismo disco (no /tmp, que puede ser RAM)
    snap = path + ".recup_snap"
    print(f"[i] Copiando snapshot ({size_mb} MB)...")
    shutil.copy2(path, snap)
    try:
        with open(snap) as f:
            data = json.load(f)
    except MemoryError:
        os.remove(snap)
        print("[X] Sin memoria para parsear. Para Node-RED y reintenta:")
        print("    sudo systemctl stop nodered && python3 recuperar_cola.py && sudo systemctl start nodered")
        sys.exit(3)
    finally:
        if os.path.exists(snap):
            os.remove(snap)

    queue = find_queue(data) or []
    print(f"[i] Mensajes en la cola: {len(queue)}")

    groups = defaultdict(list)
    sin = 0
    for m in queue:
        if not isinstance(m, dict):
            sin += 1
            continue
        t = m.get("topic")
        p = m.get("payload")
        if t and p is not None:
            # una línea por mensaje (los payloads no llevan saltos de línea)
            groups[t].append(str(p).replace("\n", " ").replace("\r", " "))
        else:
            sin += 1
    for t in sorted(groups):
        print(f"    {t}: {len(groups[t])}")
    if sin:
        print(f"    (descartados sin topic/payload: {sin})")

    if dry:
        print("[i] --dry: no se publica nada.")
        return

    total = 0
    for t in sorted(groups):
        ps = groups[t]
        tmp = path + ".recup_pub"
        with open(tmp, "w") as f:
            f.write("\n".join(ps) + "\n")
        print(f"[~] Publicando {len(ps)} -> {t} ...")
        cmd = ["mosquitto_pub", "-h", host, "-p", port, "-t", t, "-q", "1", "-l"]
        if user:
            cmd += ["-u", user]
        if pw:
            cmd += ["-P", pw]
        r = subprocess.run(cmd, stdin=open(tmp))
        os.remove(tmp)
        if r.returncode == 0:
            total += len(ps)
            print(f"    [OK] {len(ps)} publicados")
        else:
            print(f"    [X] mosquitto_pub falló (rc={r.returncode})")

    print(f"\n[OK] Republicados {total} mensajes al broker {host}:{port}.")
    print("     Compruébalo en Elastic (índices de esas fechas). Cuando cuadre,")
    print("     vacía la cola con el botón 'Borrar cola de envío'.")


if __name__ == "__main__":
    main()
