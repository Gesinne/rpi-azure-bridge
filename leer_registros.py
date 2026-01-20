#!/usr/bin/env python3
"""
Leer y escribir registros Modbus de las tarjetas L1, L2, L3

Uso:
  Leer:    python3 leer_registros.py [tarjetas]           # Ej: python3 leer_registros.py "1 2 3"
  Escribir: python3 leer_registros.py write <tarjeta> <registro> <valor>
            python3 leer_registros.py write 1 46 2       # Escribe valor 2 en registro 46 de L1
"""
import os
import sys
import json
from datetime import datetime

# Configuración Modbus - HARDCODEADO, NO MODIFICAR
SERIAL_PORT = "/dev/ttyAMA0"
SERIAL_BAUDRATE = 115200

# Mapa de registros completo (112 registros)
REGISTROS = {
    0: ("Estado actual del chopper", "Estado actual"),
    1: ("Modo de funcionamiento (topología) actual", "Topología actual"),
    2: ("Alarma", "Alarma"),
    3: ("Tensión de salida (Vo)", "V salida"),
    4: ("Tensión de entrada (Vin)", "V entrada"),
    5: ("Frecuencia", "Hz"),
    6: ("Corriente de salida del Equipo", "I Salida"),
    7: ("Corriente de salida del Chopper", "I Chopper"),
    8: ("Corriente por primario del trafo (reflejada secundario)", "I Primario trafo"),
    9: ("Potencia activa de salida del equipo (parte alta)", "P activa (alta)"),
    10: ("Potencia activa de salida del equipo (parte baja)", "P activa (baja)"),
    11: ("Potencia reactiva de salida (parte alta)", "P reactiva (alta)"),
    12: ("Potencia reactiva de salida (parte baja)", "P reactiva (baja)"),
    13: ("Potencia aparente de salida del equipo (parte alta)", "P aparente (alta)"),
    14: ("Potencia aparente de salida del equipo (parte baja)", "P aparente (baja)"),
    15: ("Factor de potencia", "Factor de Potencia"),
    16: ("Tipo de factor de potencia", "Tipo de FP"),
    17: ("Temperatura interna", "Temperatura"),
    18: ("Temperatura para despejar alarma", "Temperatura de alarma"),
    19: ("Estado del Enable de regulación externo", "Enable externo"),
    20: ("Tiempo restante para reencendido", "Tiempo para despejar"),
    21: ("Estado del Enable de regulación Switch PCB", "Enable PCB"),
    22: ("N/A", "N/A"), 23: ("N/A", "N/A"), 24: ("N/A", "N/A"), 25: ("N/A", "N/A"),
    26: ("N/A", "N/A"), 27: ("N/A", "N/A"), 28: ("N/A", "N/A"), 29: ("N/A", "N/A"),
    30: ("Flag escritura registros de ESTADO", "Flag Estado"),
    31: ("Estado deseado del Chopper", "Estado deseado"),
    32: ("Tensión de consigna deseada", "Consigna deseada"),
    33: ("Bucle de control del Chopper", "Bucle de control"),
    34: ("Mando del control del Chopper", "Mando chopper"),
    35: ("N/A", "N/A"), 36: ("N/A", "N/A"), 37: ("N/A", "N/A"), 38: ("N/A", "N/A"), 39: ("N/A", "N/A"),
    40: ("Flag escritura registros de CONFIGURACIÓN", "Flag Configuración"),
    41: ("Número de serie", "Nº de serie placas"),
    42: ("Tensión nominal", "V nominal"),
    43: ("Tensión de primario del autotransformador", "V primario autotrafo"),
    44: ("Tensión de primario del transformador", "V secundario autotrafo"),
    45: ("Tensión de secundario del transformador", "V secundario trafo"),
    46: ("Topología del equipo", "Topología"),
    47: ("Dead-time (DT)", "Dead-time"),
    48: ("Dirección MODBUS", "Modbus"),
    49: ("Corriente nominal de medida de salida del Equipo", "I nominal salida"),
    50: ("Corriente nominal de medida de salida del Chopper", "I nominal chopper"),
    51: ("Corriente máxima chopper (valor eficaz)", "I máxima chopper"),
    52: ("Corriente máxima chopper (valor pico)", "I máxima chopper"),
    53: ("Tiempo de apagado después de CC/TT", "Tiempo de apagado CC/TT"),
    54: ("Número de apagados por sobrecorriente", "Contador apagados SC"),
    55: ("Estado inicial del Chopper", "Estado inicial"),
    56: ("Tensión de consigna inicial", "V inicial"),
    57: ("Temperatura interna máxima", "Temperatura máxima"),
    58: ("Decremento de temperatura para reencendido", "Decremento T reenc"),
    59: ("Número de apagados por sobretemperatura", "Contador apagados ST"),
    60: ("Tipo de alimentación de la placa", "Tipo V placa"),
    61: ("Velocidad de comunicación MODBUS", "Velocidad Modbus"),
    62: ("Empaquetado (package) de los transistores", "Package transistores"),
    63: ("Ángulo de cambio de tensión para cargas altas", "Ángulo cargas altas"),
    64: ("Ángulo de cambio de tensión para cargas bajas", "Ángulo cargas bajas"),
    65: ("Porcentaje de corriente máxima para carga baja", "% para carga baja"),
    66: ("Sensibilidad detección transitorios", "Sensibilidad transitorios"),
    67: ("Sensibilidad detección derivada corriente", "Sensibilidad derivada"),
    68: ("N/A", "N/A"),
    69: ("Restablece la configuración por defecto", "?ReCo"),
    70: ("Flag escritura registros de CALIBRACIÓN", "Flag Calibración"),
    71: ("Parámetro K de la tensión de salida V0", "?Ca00"),
    72: ("Parámetro K de la tensión de entrada Vin", "?Ca01"),
    73: ("Parámetro b de la tensión de salida V0", "?Ca03"),
    74: ("Parámetro b de la tensión de entrada Vin", "?Ca04"),
    75: ("Parámetro K de la corriente de salida del Chopper", "?Ca06"),
    76: ("Parámetro K de la corriente de salida del Equipo", "?Ca07"),
    77: ("Parámetro b de la corriente de salida del Chopper", "?Ca08"),
    78: ("Parámetro b de la corriente de salida del Equipo", "?Ca09"),
    79: ("Valor del ruido de la corriente del Chopper", "?Ca10"),
    80: ("Valor del ruido de la corriente del Equipo", "?Ca11"),
    81: ("Parámetro K de la potencia de salida", "?Ca12"),
    82: ("Parámetro b de la potencia de salida", "?Ca13"),
    83: ("Desfase de muestras entre tensión y corriente", "?Ca14"),
    84: ("Parámetro de calibración de la medida de frecuencia", "?Ca15"),
    85: ("Calibra el ruido de los canales de corriente", "?R"),
    86: ("Restablece la calibración por defecto", "?ReCa"),
    87: ("N/A", "N/A"), 88: ("N/A", "N/A"), 89: ("N/A", "N/A"),
    90: ("Flag escritura registros de CONTROL", "Flag Control"),
    91: ("Parámetro A del control de tensión", "?Cn00"),
    92: ("Parámetro B del control de tensión", "?Cn01"),
    93: ("Escalón máximo del mando de tensión (EMM)", "?Cn02"),
    94: ("Escalón máximo del mando tensión nula (EMMVT0)", "?Cn03"),
    95: ("Escalón máximo del mando tensión no nula (EMMVT1)", "?ReCn"),
    96: ("Parámetro Cn05", "Cn05"),
    97: ("N/A", "N/A"), 98: ("N/A", "N/A"), 99: ("N/A", "N/A"),
    100: ("Versión del firmware", "Versión FW"),
    101: ("Tipo de firmware", "Tipo FW"),
    102: ("Tipo de microprocesador", "Microproc"),
    103: ("FLASH restante", "FLASH rest"),
    104: ("Frecuencia PWM", "Frec PWM"),
    105: ("Mando de apagado", "Mando apag"),
    106: ("Mando mínimo", "Mando mín"),
    107: ("Mando máximo", "Mando máx"),
    108: ("N/A", "N/A"), 109: ("N/A", "N/A"),
    110: ("Flag de reset", "Flag Reset"),
    111: ("Reset del firmware", "RESET FW"),
}


# Número total de registros a leer
TOTAL_REGISTROS = 112


def leer_tarjeta(client, unit_id):
    """Lee todos los registros de una tarjeta"""
    data = []
    for start in range(0, TOTAL_REGISTROS, 40):
        count = min(40, TOTAL_REGISTROS - start)
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


def escribir_registro(unit_id, registro, valor, bypass_automatico=True):
    """Escribe un valor en un registro específico de una tarjeta
    
    Args:
        unit_id: ID de la tarjeta (1, 2 o 3)
        registro: Número de registro (0-95)
        valor: Valor a escribir
        bypass_automatico: Si True, pone el equipo en bypass (reg 31=0) antes de escribir reg 56
    """
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
    
    resultado = {
        "success": False,
        "unit_id": unit_id,
        "registro": registro,
        "valor": valor,
        "timestamp": datetime.now().isoformat(),
        "mensaje": "",
        "bypass_aplicado": False
    }
    
    if registro not in REGISTROS:
        resultado["mensaje"] = f"Registro {registro} no válido (0-95)"
        return resultado
    
    desc, nombre = REGISTROS[registro]
    resultado["nombre_registro"] = nombre
    resultado["descripcion"] = desc
    
    if client.connect():
        estado_anterior_reg31 = None
        
        # Si es registro 56 (V inicial), primero poner en bypass (registro 31 = 0)
        if registro == 56 and bypass_automatico:
            # Leer estado actual del registro 31
            reg31_result = client.read_holding_registers(address=31, count=1, slave=unit_id)
            if not reg31_result.isError():
                estado_anterior_reg31 = reg31_result.registers[0]
                resultado["estado_deseado_anterior"] = estado_anterior_reg31
            
            # Poner en bypass: registro 31 = 0
            bypass_result = client.write_register(address=31, value=0, slave=unit_id)
            if bypass_result.isError():
                resultado["mensaje"] = f"Error al poner en bypass (reg 31=0): {bypass_result}"
                client.close()
                return resultado
            resultado["bypass_aplicado"] = True
            
            # Pequeña pausa para que el equipo procese el cambio
            import time
            time.sleep(0.1)
        
        # Leer valor actual antes de escribir
        read_result = client.read_holding_registers(address=registro, count=1, slave=unit_id)
        if not read_result.isError():
            resultado["valor_anterior"] = read_result.registers[0]
        
        # Escribir el nuevo valor
        write_result = client.write_register(address=registro, value=valor, slave=unit_id)
        
        if not write_result.isError():
            resultado["success"] = True
            resultado["mensaje"] = f"Registro {registro} ({nombre}) escrito correctamente en L{unit_id}"
            
            # Verificar escritura leyendo de nuevo
            verify_result = client.read_holding_registers(address=registro, count=1, slave=unit_id)
            if not verify_result.isError():
                resultado["valor_verificado"] = verify_result.registers[0]
                if verify_result.registers[0] != valor:
                    resultado["success"] = False
                    resultado["mensaje"] = f"Verificación fallida: esperado {valor}, leído {verify_result.registers[0]}"
            
            # Restaurar estado anterior del registro 31 si se aplicó bypass
            if resultado["bypass_aplicado"] and estado_anterior_reg31 is not None:
                import time
                time.sleep(0.1)
                restore_result = client.write_register(address=31, value=estado_anterior_reg31, slave=unit_id)
                if not restore_result.isError():
                    resultado["estado_restaurado"] = estado_anterior_reg31
                    resultado["mensaje"] += f" (estado restaurado a {estado_anterior_reg31})"
                else:
                    resultado["mensaje"] += f" (AVISO: no se pudo restaurar estado anterior)"
        else:
            resultado["mensaje"] = f"Error al escribir: {write_result}"
            # Intentar restaurar bypass aunque falle la escritura
            if resultado["bypass_aplicado"] and estado_anterior_reg31 is not None:
                client.write_register(address=31, value=estado_anterior_reg31, slave=unit_id)
        
        client.close()
    else:
        resultado["mensaje"] = "Error: No se pudo conectar al puerto serie"
    
    return resultado


def escribir_multiples_registros(unit_id, registros_valores):
    """Escribe múltiples registros en una tarjeta
    
    Args:
        unit_id: ID de la tarjeta (1, 2 o 3)
        registros_valores: dict {registro: valor, ...}
    """
    resultados = []
    for registro, valor in registros_valores.items():
        resultado = escribir_registro(unit_id, int(registro), int(valor))
        resultados.append(resultado)
    return resultados


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "write":
        # Modo escritura: python3 leer_registros.py write <tarjeta> <registro> <valor>
        if len(sys.argv) < 5:
            print("Uso: python3 leer_registros.py write <tarjeta> <registro> <valor>")
            print("Ejemplo: python3 leer_registros.py write 1 46 2")
            sys.exit(1)
        
        unit_id = int(sys.argv[2])
        registro = int(sys.argv[3])
        valor = int(sys.argv[4])
        
        print(f"Escribiendo valor {valor} en registro {registro} de L{unit_id}...")
        resultado = escribir_registro(unit_id, registro, valor)
        
        if resultado["success"]:
            print(f"✓ {resultado['mensaje']}")
            if "valor_anterior" in resultado:
                print(f"  Valor anterior: {resultado['valor_anterior']}")
            if "valor_verificado" in resultado:
                print(f"  Valor verificado: {resultado['valor_verificado']}")
        else:
            print(f"✗ Error: {resultado['mensaje']}")
        
        print(json.dumps(resultado, indent=2))
    else:
        # Modo lectura (comportamiento original)
        tarjetas = sys.argv[1] if len(sys.argv) > 1 else "1 2 3"
        print(leer_todas_tarjetas(tarjetas))
