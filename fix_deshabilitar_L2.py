#!/usr/bin/env python3
"""
Deshabilita (o reactiva) la lectura Modbus de la placa L2 (Tarjeta2) en el flow.

PROBLEMA: cuando la placa L2 se queda muda (transceptor RS-485 muerto), su lectura
da timeout y el cliente Modbus de Node-RED entra en RECONEXIÓN PERMANENTE
("Modbus queue cleared on reconnect" / "Timed out") → degrada la lectura de L1 y L3.

SOLUCIÓN: poner el getter "Tarjeta2" en 'disabled' (d:true) → el bus deja de
preguntarle → L1/L3 se leen limpias y estables. AlarmasL2 ya está a 0 (no hay dato),
así que no falsea la regulación/ahorro.

Uso:
    sudo python3 fix_deshabilitar_L2.py            # deshabilita Tarjeta2
    sudo python3 fix_deshabilitar_L2.py --enable   # la vuelve a habilitar (tras cambiar la placa)

Reversible. Hace backup del flows.json. Reinicia Node-RED al terminar.
OJO: si luego se hace "Actualizar Flow" (baja del repo NODERED) se revierte —
para hacerlo permanente hay que commitearlo también en el repo NODERED.
"""
import json, os, glob, sys, time, shutil, subprocess

ENABLE = '--enable' in sys.argv

cands = glob.glob('/home/*/.node-red/flows.json') + ['/root/.node-red/flows.json']
f = next((p for p in cands if os.path.exists(p)), None)
if not f:
    print("[X] no encuentro flows.json"); sys.exit(1)
print("[i] flow:", f)

with open(f) as fh:
    flows = json.load(fh)

# Localiza el getter de Tarjeta2 (por nombre; fallback por unitid=2)
targets = [n for n in flows if n.get('type') == 'modbus-flex-getter'
           and 'tarjeta2' in str(n.get('name', '')).lower()]
if not targets:
    targets = [n for n in flows if n.get('type') == 'modbus-flex-getter'
               and str(n.get('unitid', '')) == '2']
if not targets:
    print("[X] no encontré el getter de Tarjeta2 (modbus-flex-getter). Nada que hacer."); sys.exit(1)

print("[!] Parando Node-RED para editar el flow...")
subprocess.run(['systemctl', 'stop', 'nodered'], stderr=subprocess.DEVNULL)
time.sleep(2)

bak = f + '.bak.' + time.strftime('%Y%m%d-%H%M%S')
shutil.copy2(f, bak)
print("[i] backup:", bak)

for n in targets:
    if ENABLE:
        n.pop('d', None)
        print("  [OK] HABILITADO getter '%s' (id %s)" % (n.get('name'), n.get('id')))
    else:
        n['d'] = True
        print("  [OK] DESHABILITADO getter '%s' (id %s)" % (n.get('name'), n.get('id')))

with open(f, 'w') as fh:
    json.dump(flows, fh)

print("[~] Reiniciando Node-RED...")
subprocess.run(['systemctl', 'start', 'nodered'], stderr=subprocess.DEVNULL)
print("[OK] Listo. Verifica que desaparecen los errores:  sudo journalctl -u nodered -f")
