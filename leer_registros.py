#!/usr/bin/env python3
"""
Leer registros Modbus de las tarjetas L1, L2, L3 y enviar por email
"""
import os
import sys
import json
from datetime import datetime

# Configuración desde variables de entorno
SERIAL_PORT = os.getenv('SERIAL_PORT', '/dev/ttyAMA0')
SERIAL_BAUDRATE = int(os.getenv('SERIAL_BAUDRATE', '115200'))
NUMERO_SERIE = os.getenv('NUMERO_SERIE', 'unknown')

# Mapa de registros
REGISTROS = {
    0: ("Estado actual del chopper", "Estado actual"),
    1: ("Modo de funcionamiento", "Topología actual"),
    2: ("Alarma", "Alarma"),
    3: ("Tensión de salida (Vo)", "V salida"),
    4: ("Tensión de entrada (Vin)", "V entrada"),
    5: ("Frecuencia", "Hz"),
    6: ("Corriente salida Equipo", "I Salida"),
    7: ("Corriente salida Chopper", "I Chopper"),
    8: ("Corriente primario trafo", "I Primario"),
    9: ("Potencia activa (alta)", "P activa (alta)"),
    10: ("Potencia activa (baja)", "P activa (baja)"),
    11: ("Potencia reactiva (alta)", "P reactiva (alta)"),
    12: ("Potencia reactiva (baja)", "P reactiva (baja)"),
    13: ("Potencia aparente (alta)", "P aparente (alta)"),
    14: ("Potencia aparente (baja)", "P aparente (baja)"),
    15: ("Factor de potencia", "Factor Potencia"),
    16: ("Tipo factor potencia", "Tipo FP"),
    17: ("Temperatura interna", "Temperatura"),
    18: ("Temperatura alarma", "Temp alarma"),
    19: ("Enable externo", "Enable externo"),
    20: ("Tiempo reencendido", "Tiempo reenc"),
    21: ("Enable PCB", "Enable PCB"),
    30: ("Flag Estado", "Flag Estado"),
    31: ("Estado deseado", "Estado deseado"),
    32: ("Consigna deseada", "Consigna"),
    33: ("Bucle control", "Bucle control"),
    34: ("Mando chopper", "Mando chopper"),
    40: ("Flag Configuración", "Flag Config"),
    41: ("Número de serie", "Nº serie"),
    42: ("Tensión nominal", "V nominal"),
    43: ("V primario autotrafo", "V prim auto"),
    44: ("V secundario autotrafo", "V sec auto"),
    45: ("V secundario trafo", "V sec trafo"),
    46: ("Topología", "Topología"),
    47: ("Dead-time", "Dead-time"),
    48: ("Dirección MODBUS", "Modbus"),
    49: ("I nominal salida", "I nom salida"),
    50: ("I nominal chopper", "I nom chopper"),
    51: ("I máxima chopper eficaz", "I max eficaz"),
    52: ("I máxima chopper pico", "I max pico"),
    53: ("Tiempo apagado CC/TT", "T apagado"),
    54: ("Contador apagados SC", "Cnt SC"),
    55: ("Estado inicial", "Estado ini"),
    56: ("V inicial", "V inicial"),
    57: ("Temperatura máxima", "Temp máx"),
    58: ("Decremento T", "Decr T"),
    59: ("Contador apagados ST", "Cnt ST"),
    60: ("Tipo V placa", "Tipo V"),
    61: ("Velocidad Modbus", "Vel Modbus"),
    62: ("Package transistores", "Package"),
    63: ("Ángulo cargas altas", "Áng altas"),
    64: ("Ángulo cargas bajas", "Áng bajas"),
    65: ("% carga baja", "% carga baja"),
    66: ("Sensibilidad transitorios", "Sens trans"),
    67: ("Sensibilidad derivada", "Sens deriv"),
    69: ("Reset config", "?ReCo"),
    70: ("Flag Calibración", "Flag Calib"),
    71: ("K tensión salida", "?Ca00"),
    72: ("K tensión entrada", "?Ca01"),
    73: ("b tensión salida", "?Ca03"),
    74: ("b tensión entrada", "?Ca04"),
    75: ("K corriente chopper", "?Ca06"),
    76: ("K corriente equipo", "?Ca07"),
    77: ("b corriente chopper", "?Ca08"),
    78: ("b corriente equipo", "?Ca09"),
    79: ("Ruido I chopper", "?Ca10"),
    80: ("Ruido I equipo", "?Ca11"),
    81: ("K potencia salida", "?Ca12"),
    82: ("b potencia salida", "?Ca13"),
    83: ("Desfase V-I", "?Ca14"),
    84: ("Calib frecuencia", "?Ca15"),
    85: ("Calib ruido I", "?R"),
    86: ("Reset calibración", "?ReCa"),
    90: ("Flag Control", "Flag Control"),
    91: ("Parámetro A control", "?Cn00"),
    92: ("Parámetro B control", "?Cn01"),
    93: ("Escalón max EMM", "?Cn02"),
    94: ("Escalón max V0", "?Cn03"),
    95: ("Escalón max V1", "?ReCn"),
}


def leer_tarjeta(client, unit_id):
    """Lee todos los registros de una tarjeta"""
    data = []
    for start in range(0, 96, 40):
        count = min(40, 96 - start)
        result = client.read_holding_registers(address=start, count=count, slave=unit_id)
        if not result.isError():
            data.extend(result.registers)
        else:
            break
    return data


def formatear_tabla(data, fase):
    """Formatea los datos en tabla de texto"""
    if len(data) < 48:
        return f"Error: No se pudieron leer registros de {fase}\n"
    
    dir_modbus = data[48]
    placa = {1: "L1 (Fase 1)", 2: "L2 (Fase 2)", 3: "L3 (Fase 3)"}.get(dir_modbus, "Desconocida")
    
    lines = []
    lines.append("")
    lines.append("╔══════════════════════════════════════════════════════════════════════════════╗")
    lines.append(f"║  PLACA: {placa:20s}  -  Dirección Modbus: {dir_modbus}                        ║")
    lines.append("╚══════════════════════════════════════════════════════════════════════════════╝")
    lines.append("")
    lines.append("Reg | Parámetro                | Valor      | Descripción")
    lines.append("----|--------------------------|------------|--------------------------------------------------")
    
    for i in range(len(data)):
        if i in REGISTROS:
            desc, nombre = REGISTROS[i]
            lines.append(f"{i:3d} | {nombre:24s} | {data[i]:10d} | {desc}")
    
    return "\n".join(lines)


def leer_todas_tarjetas(tarjetas="1 2 3"):
    """Lee las tarjetas especificadas y devuelve el texto formateado"""
    try:
        from pymodbus.client import ModbusSerialClient
    except ImportError:
        from pymodbus.client.sync import ModbusSerialClient
    
    client = ModbusSerialClient(
        port=SERIAL_PORT,
        baudrate=SERIAL_BAUDRATE,
        bytesize=8,
        parity='N',
        stopbits=1,
        timeout=1
    )
    
    resultado = []
    resultado.append("=" * 80)
    resultado.append(f"PARÁMETROS DE CONFIGURACIÓN - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    resultado.append(f"Equipo S/N: {NUMERO_SERIE}")
    resultado.append("=" * 80)
    
    if client.connect():
        for unit_id in [int(x) for x in tarjetas.split()]:
            fase = f"L{unit_id}"
            data = leer_tarjeta(client, unit_id)
            resultado.append(formatear_tabla(data, fase))
        client.close()
    else:
        resultado.append("Error: No se pudo conectar al puerto serie")
    
    resultado.append("")
    resultado.append("=" * 80)
    
    return "\n".join(resultado)


def obtener_json_configuracion(tarjetas="1 2 3"):
    """Obtiene la configuración en formato JSON"""
    try:
        from pymodbus.client import ModbusSerialClient
    except ImportError:
        from pymodbus.client.sync import ModbusSerialClient
    
    client = ModbusSerialClient(
        port=SERIAL_PORT,
        baudrate=SERIAL_BAUDRATE,
        bytesize=8,
        parity='N',
        stopbits=1,
        timeout=1
    )
    
    config_data = {
        "numero_serie": NUMERO_SERIE,
        "timestamp": datetime.now().isoformat(),
        "tarjetas": {}
    }
    
    if client.connect():
        for unit_id in [int(x) for x in tarjetas.split()]:
            fase = f"L{unit_id}"
            data = leer_tarjeta(client, unit_id)
            
            if len(data) > 66:
                config_data["tarjetas"][fase] = {
                    "direccion_modbus": data[48],
                    "numero_serie_placa": data[41],
                    "v_nominal": data[42],
                    "v_primario_auto": data[43],
                    "v_secundario_auto": data[44],
                    "v_secundario_trafo": data[45],
                    "topologia": data[46],
                    "dead_time": data[47],
                    "estado_inicial": data[55],
                    "v_inicial": data[56],
                    "temp_maxima": data[57],
                    "angulo_cargas_altas": data[63],
                    "angulo_cargas_bajas": data[64],
                    "sensibilidad_transitorios": data[66],
                    "registros_raw": data
                }
        client.close()
    
    return config_data


if __name__ == "__main__":
    # Si se ejecuta directamente, mostrar por pantalla
    tarjetas = sys.argv[1] if len(sys.argv) > 1 else "1 2 3"
    print(leer_todas_tarjetas(tarjetas))
