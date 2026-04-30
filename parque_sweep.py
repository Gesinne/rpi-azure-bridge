#!/usr/bin/env python3
"""
Barrido del parque ChopperAC.

Para cada cliente del fichero de configuracion:
  - SSH a la RPi
  - Recoge informe Modbus de las ultimas 24h
  - Parsea metricas clave (timeouts, rachas, ratio entre fases)
  - Genera tabla resumen y veredicto por cliente
  - Opcionalmente envia el informe por email

Uso:
    # Crear fichero de clientes (formato: IP,nombre):
    cat > /etc/chopperac/clientes.txt << EOF
    192.168.1.10,Cliente_Norte
    192.168.1.20,Cliente_Sur
    192.168.1.30,Cliente_Este
    EOF

    # Barrer y mostrar en pantalla:
    python3 parque_sweep.py --clientes /etc/chopperac/clientes.txt

    # Barrer y enviar por email:
    python3 parque_sweep.py --clientes /etc/chopperac/clientes.txt \\
        --email patry@cesinel.com \\
        --smtp-user soporte@cesinel.com --smtp-pass XXXX

Requisitos:
  - SSH key auth a cada cliente (sin password)
  - Cada cliente debe tener ~/rpi-azure-bridge clonado
"""
import argparse
import subprocess
import re
import os
import sys
from datetime import datetime


def analyze_client(ip, ssh_user="gesinne", timeout=60):
    """SSH a un cliente y obtiene su informe Modbus."""
    cmd = [
        "ssh",
        "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=no",
        "-o", "BatchMode=yes",
        f"{ssh_user}@{ip}",
        "cd ~/rpi-azure-bridge && git pull > /dev/null 2>&1; "
        "sudo journalctl --since '24 hours ago' "
        "| python3 ~/rpi-azure-bridge/analiza_logs_modbus.py 2>/dev/null"
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if result.returncode != 0:
            return None, f"SSH fallo (rc={result.returncode}): {result.stderr.strip()[:100]}"
        return result.stdout, None
    except subprocess.TimeoutExpired:
        return None, "Timeout SSH"
    except Exception as e:
        return None, f"Excepcion: {e}"


def parse_metrics(report):
    """Parsea el informe para extraer metricas clave."""
    metrics = {
        "timeouts": {},
        "rachas": 0,
        "fsm_reconnects": 0,
        "duration_h": 0,
    }

    m = re.search(r"Duracion:\s*([\d.]+)\s*horas", report)
    if m:
        metrics["duration_h"] = float(m.group(1))

    in_timeouts = False
    for line in report.split("\n"):
        if "Timeouts por slave" in line:
            in_timeouts = True
            continue
        if in_timeouts:
            if line.strip().startswith("---"):
                in_timeouts = False
                continue
            m = re.match(r"\s+(Tarjeta\d+)\s*(?:\(.*?\))?\s+(\d+)\s+\(", line)
            if m:
                metrics["timeouts"][m.group(1)] = int(m.group(2))

    m = re.search(r"^\s+reconnect\s+(\d+)", report, re.M)
    if m:
        metrics["fsm_reconnects"] = int(m.group(1))

    metrics["rachas"] = len(re.findall(r"^\s*#\d+\s+", report, re.M))

    return metrics


def diagnose(metrics):
    """Determina veredicto y razonamiento. Devuelve (estado, detalle, prioridad)."""
    if metrics["duration_h"] < 1:
        return "[SIN DATOS]", "Logs insuficientes", 0

    timeouts = list(metrics["timeouts"].values())
    if not timeouts or all(t == 0 for t in timeouts):
        return "[OK]", "Sin timeouts en 24h", 1

    max_t = max(timeouts)
    min_t = max(min(timeouts), 1)
    total_h = sum(timeouts) / metrics["duration_h"]
    ratio = max_t / min_t
    rachas_dia = metrics["rachas"] * 24 / metrics["duration_h"]

    detalle = f"ratio={ratio:.0f}x, {total_h:.0f}t/h, {rachas_dia:.0f}rachas/d"

    if ratio > 10 and total_h > 50:
        return "[ALTO RIESGO]", detalle, 4
    if ratio > 10 or total_h > 50:
        return "[RIESGO MEDIO]", detalle, 3
    if ratio > 5 or total_h > 20:
        return "[VIGILAR]", detalle, 2
    return "[OK]", detalle, 1


def send_email(destino, smtp_host_port, user, password, asunto, cuerpo):
    import smtplib
    from email.mime.text import MIMEText
    msg = MIMEText(cuerpo)
    msg["Subject"] = asunto
    msg["From"] = user
    msg["To"] = destino
    host, port = smtp_host_port.split(":")
    with smtplib.SMTP(host, int(port)) as smtp:
        smtp.starttls()
        smtp.login(user, password)
        smtp.send_message(msg)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--clientes", default="/etc/chopperac/clientes.txt",
                   help="Fichero con lista de clientes (IP,nombre por linea)")
    p.add_argument("--ssh-user", default="gesinne")
    p.add_argument("--out", default="/tmp/parque_informe.txt")
    p.add_argument("--email", help="Direccion email destino")
    p.add_argument("--smtp", default="smtp.gmail.com:587")
    p.add_argument("--smtp-user", help="Usuario SMTP")
    p.add_argument("--smtp-pass", help="Password SMTP")
    p.add_argument("--quiet", action="store_true", help="No imprimir detalle por cliente")
    args = p.parse_args()

    if not os.path.exists(args.clientes):
        print(f"[!] No se encuentra {args.clientes}")
        print("[!] Crea el fichero con formato: IP,nombre (uno por linea)")
        sys.exit(1)

    clientes = []
    with open(args.clientes) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(",", 1)
            ip = parts[0].strip()
            nombre = parts[1].strip() if len(parts) > 1 else ip
            clientes.append((ip, nombre))

    if not args.quiet:
        print(f"[*] Barriendo {len(clientes)} clientes...\n")

    resultados = []
    for ip, nombre in clientes:
        if not args.quiet:
            print(f"  [{ip}] {nombre}... ", end="", flush=True)
        report, error = analyze_client(ip, args.ssh_user)
        if report is None:
            estado = "[INACCESIBLE]"
            detalle = error or "?"
            prioridad = 0
        else:
            metrics = parse_metrics(report)
            estado, detalle, prioridad = diagnose(metrics)
        resultados.append((ip, nombre, estado, detalle, prioridad))
        if not args.quiet:
            print(estado)

    resultados.sort(key=lambda r: -r[4])

    lineas = []
    lineas.append(f"INFORME PARQUE CHOPPERAC")
    lineas.append(f"Fecha: {datetime.now().isoformat(timespec='seconds')}")
    lineas.append(f"Total clientes: {len(clientes)}")
    lineas.append("=" * 90)
    lineas.append(f"{'Cliente':<20} {'IP':<16} {'Estado':<18} {'Detalle':<35}")
    lineas.append("-" * 90)
    for ip, nombre, estado, detalle, _ in resultados:
        lineas.append(f"{nombre:<20} {ip:<16} {estado:<18} {detalle:<35}")
    lineas.append("=" * 90)

    contadores = {}
    for _, _, estado, _, _ in resultados:
        contadores[estado] = contadores.get(estado, 0) + 1

    lineas.append("")
    lineas.append("Resumen:")
    for estado in ["[ALTO RIESGO]", "[RIESGO MEDIO]", "[VIGILAR]", "[OK]", "[SIN DATOS]", "[INACCESIBLE]"]:
        if estado in contadores:
            lineas.append(f"  {estado:<18} {contadores[estado]:>3} clientes")

    lineas.append("")
    lineas.append("Accion sugerida:")
    if contadores.get("[ALTO RIESGO]", 0) > 0:
        lineas.append("  - URGENTE: visitar clientes [ALTO RIESGO] para instalar terminador 120 ohm")
    if contadores.get("[RIESGO MEDIO]", 0) > 0:
        lineas.append("  - Programar visita a clientes [RIESGO MEDIO] en proxima ronda")
    if contadores.get("[INACCESIBLE]", 0) > 0:
        lineas.append("  - Verificar conectividad y SSH key de clientes [INACCESIBLE]")

    informe = "\n".join(lineas)

    if not args.quiet:
        print()
    print(informe)

    with open(args.out, "w") as f:
        f.write(informe + "\n")
    if not args.quiet:
        print(f"\n[*] Guardado en {args.out}")

    if args.email:
        if not (args.smtp_user and args.smtp_pass):
            print("[!] --email requiere --smtp-user y --smtp-pass")
            sys.exit(1)
        try:
            send_email(args.email, args.smtp, args.smtp_user, args.smtp_pass,
                       f"ChopperAC parque - {datetime.now().date()}", informe)
            print(f"[*] Email enviado a {args.email}")
        except Exception as e:
            print(f"[!] Error enviando email: {e}")
            sys.exit(2)


if __name__ == "__main__":
    main()
