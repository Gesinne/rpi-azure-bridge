#!/usr/bin/env python3
"""
Port-attack: manipulacion agresiva del puerto serie para intentar
despertar PCBs colgadas.

Tres patrones:
  1) Cierre largo (10s) + reapertura con bombardeo
  2) 20 cierres rapidos consecutivos
  3) Baud-hopping con puerto siempre abierto

Uso (con Node-RED parado):
    sudo systemctl stop nodered
    sudo fuser -k /dev/ttyAMA0
    python3 port_attack.py
    sudo systemctl start nodered
"""
import serial
import struct
import time
import sys


def crc16(d):
    crc = 0xFFFF
    for b in d:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def make_frame(slave, fc, reg, val):
    pdu = struct.pack('>BBHH', slave, fc, reg, val)
    return pdu + struct.pack('<H', crc16(pdu))


def check_resp(name, sl, resp):
    """Devuelve True si la respuesta es valida del slave esperado."""
    if len(resp) >= 7 and resp[0] == sl and resp[1] == 3:
        val = struct.unpack('>H', resp[3:5])[0]
        print(f'  >>> {name} RESPONDE!! reg 0 = {val}')
        print(f'  Bytes: {resp.hex()}')
        return True
    elif len(resp) > 0:
        print(f'  {name}: garbled {resp.hex()[:60]}')
    return False


def main():
    PORT = '/dev/ttyAMA0'
    BAUD = 115200

    read_s2 = make_frame(2, 3, 0, 1)
    read_s3 = make_frame(3, 3, 0, 1)
    reset_bcast = make_frame(0, 6, 110, 1)

    print()
    print('=' * 50)
    print('PORT-ATTACK: 3 patrones agresivos')
    print('=' * 50)

    # ============== Patron 1: Cierre largo ==============
    print()
    print('>>> Test 1: Cierre 10s + reapertura ataque (5 ciclos)')
    for ciclo in range(5):
        s = serial.Serial(PORT, BAUD, timeout=0.3)
        s.break_condition = True
        time.sleep(1.0)
        s.break_condition = False
        time.sleep(0.1)
        s.close()

        print(f'  Ciclo {ciclo+1}/5: puerto CERRADO 10s...')
        time.sleep(10)

        s = serial.Serial(PORT, BAUD, timeout=0.5)
        for _ in range(3):
            s.write(reset_bcast)
            time.sleep(0.05)

        for sl, frame in [(2, read_s2), (3, read_s3)]:
            s.reset_input_buffer()
            s.write(frame)
            time.sleep(0.5)
            resp = s.read(100)
            check_resp(f'Slave {sl}', sl, resp)

        s.close()

    # ============== Patron 2: Cierres rapidos ==============
    print()
    print('>>> Test 2: 20 cierres rapidos consecutivos')
    for ciclo in range(20):
        s = serial.Serial(PORT, BAUD, timeout=0.2)
        s.write(reset_bcast)
        s.close()
        time.sleep(0.1)

    time.sleep(2)
    s = serial.Serial(PORT, BAUD, timeout=1.0)
    for sl, frame in [(2, read_s2), (3, read_s3)]:
        s.reset_input_buffer()
        s.write(frame)
        time.sleep(1.0)
        resp = s.read(100)
        check_resp(f'Slave {sl}', sl, resp)
    s.close()

    # ============== Patron 3: Baud-hopping ==============
    print()
    print('>>> Test 3: Baud-hop rapido')
    s = serial.Serial(PORT, BAUD, timeout=0.2)
    for ciclo in range(50):
        for baud in [9600, 19200, 38400, 115200]:
            s.baudrate = baud
            s.write(reset_bcast)
            time.sleep(0.02)

    s.baudrate = BAUD
    time.sleep(2)
    for sl, frame in [(2, read_s2), (3, read_s3)]:
        s.reset_input_buffer()
        s.write(frame)
        time.sleep(1.0)
        resp = s.read(100)
        check_resp(f'Slave {sl}', sl, resp)
    s.close()

    # ============== Patron 4: BREAK + multiple bauds ==============
    print()
    print('>>> Test 4: BREAK + comandos en cada baud')
    for baud in [9600, 19200, 38400, 57600, 115200]:
        s = serial.Serial(PORT, baud, timeout=0.5)
        # BREAK de 500ms:
        s.break_condition = True
        time.sleep(0.5)
        s.break_condition = False
        time.sleep(0.1)
        # Reset broadcast:
        for _ in range(3):
            s.write(reset_bcast)
            time.sleep(0.05)
        # Leer slaves:
        for sl, frame in [(2, read_s2), (3, read_s3)]:
            s.reset_input_buffer()
            s.write(frame)
            time.sleep(0.5)
            resp = s.read(100)
            if check_resp(f'Baud {baud} Slave {sl}', sl, resp):
                print(f'  !!! BAUD CORRECTO ENCONTRADO: {baud} !!!')
        s.close()

    print()
    print('=' * 50)
    print('TERMINADO. Ejecuta scan_modbus.py --quick para verificar.')
    print('=' * 50)


if __name__ == "__main__":
    main()
