#!/usr/bin/env python3
"""
El portero del servidor de acceso: convierte un túnel en una pestaña del navegador.

El túnel deja la terminal y la pantalla de la Raspberry en dos puertos del localhost de
este servidor. Eso ya sirve para entrar con ssh, pero obliga a tener clave en cada
portátil y a pelearse con el salto. Lo que quiere cualquiera es pulsar un botón en el
panel y verlo.

Esto es la pieza que falta en medio, y hace tres cosas:

  - El panel pide una sesión (con su token, por el 127.0.0.1) diciendo de qué equipo y
    si quiere terminal o pantalla.
  - Se levanta aquí el programa que corresponde -- ttyd para la terminal, websockify
    con noVNC para la pantalla -- escuchando sólo en el localhost.
  - Se devuelve una dirección de un solo uso que caduca. Nginx la valida contra este
    mismo portero antes de dejar pasar nada.

Quien entra en la Raspberry es este servidor, con su clave, no el ordenador de quien
mira: así nadie necesita llaves repartidas por los portátiles, y el día que alguien
deje la empresa se le quita el acceso en Keycloak y se acabó.

Las sesiones mueren solas: por tiempo, al cerrarse la pestaña (ttyd --once) y al
cerrarse el túnel. Un proceso olvidado aquí sería una puerta abierta.
"""
import http.server
import json
import os
import secrets
import shutil
import signal
import socket
import socketserver
import subprocess
import threading
import time
import urllib.parse

PUERTO_PORTERO = int(os.environ.get('PORTERO_PUERTO', '8900'))
# Rango de puertos para las sesiones; sólo escuchan en 127.0.0.1, nunca salen fuera.
PUERTO_DESDE, PUERTO_HASTA = 8950, 9100
MINUTOS_POR_DEFECTO = 30
MINUTOS_TOPE = 240
CLAVE_RPI = os.environ.get('PORTERO_CLAVE_RPI', '/etc/gesinne/acceso_rpi.key')
PUBLICA = os.environ.get('PORTERO_PUBLICA', 'https://acceso.gesinne.cloud:8443')
NOVNC = '/usr/share/novnc'

TOKEN = (os.environ.get('PORTERO_TOKEN') or '').strip()

sesiones = {}          # sid -> {proc, puerto, caduca, equipo, tipo, usuario}
candado = threading.Lock()


def registra(texto):
    print('%s portero: %s' % (time.strftime('%F %T'), texto), flush=True)


def puerto_libre():
    for p in range(PUERTO_DESDE, PUERTO_HASTA):
        with socket.socket() as s:
            try:
                s.bind(('127.0.0.1', p))
                return p
            except OSError:
                continue
    raise RuntimeError('no quedan puertos libres para sesiones')


def arranca_terminal(puerto, puerto_tunel, equipo, sid):
    """Una terminal contra la Raspberry, por el túnel.

    --base-path: la sesión no se sirve en la raíz sino bajo /s/<sid>/, y ttyd tiene que
    saberlo o pedirá sus ficheros y su websocket en la raíz y la pestaña se queda en
    blanco.

    --once: en cuanto se cierra la pestaña, el proceso se va. Sin eso quedarían
    terminales abiertas esperando a cualquiera que acertara la dirección.
    """
    orden = [
        'ttyd', '-p', str(puerto), '-i', 'lo', '--writable', '--once',
        '--base-path', '/s/%s' % sid,
        '-t', 'titleFixed=Equipo %s' % equipo, '-t', 'fontSize=15',
        'ssh', '-p', str(puerto_tunel),
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'UserKnownHostsFile=/var/lib/portero/known_hosts',
        '-i', CLAVE_RPI, 'gesinne@localhost',
    ]
    return subprocess.Popen(orden, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)


def arranca_pantalla(puerto, puerto_tunel):
    """La pantalla: websockify sirve el noVNC y lleva el VNC del túnel al navegador."""
    orden = [
        'websockify', '--web', NOVNC,
        '127.0.0.1:%d' % puerto, '127.0.0.1:%d' % puerto_tunel,
    ]
    return subprocess.Popen(orden, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)


def cierra(sid, motivo=''):
    s = sesiones.pop(sid, None)
    if not s:
        return
    try:
        s['proc'].terminate()
        try:
            s['proc'].wait(timeout=5)
        except subprocess.TimeoutExpired:
            s['proc'].kill()
    except Exception:
        pass
    registra('cerrada la sesión del %s (%s)%s' % (s['equipo'], s['tipo'], ' · ' + motivo if motivo else ''))


def barrendero():
    """Las sesiones caducadas y las que ya no tienen proceso se recogen solas."""
    while True:
        time.sleep(10)
        ahora = time.time()
        with candado:
            for sid in [k for k, v in sesiones.items()
                        if v['caduca'] < ahora or v['proc'].poll() is not None]:
                cierra(sid, 'caducada o terminada')


class Portero(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass                        # el registro lo llevamos nosotros

    def contesta(self, codigo, datos=None, cabeceras=None):
        cuerpo = json.dumps(datos or {}).encode()
        self.send_response(codigo)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(cuerpo)))
        for k, v in (cabeceras or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(cuerpo)

    def autorizado(self):
        cabecera = self.headers.get('Authorization', '')
        if not TOKEN or not cabecera.startswith('Bearer '):
            return False
        return secrets.compare_digest(cabecera[7:].strip(), TOKEN)

    def do_GET(self):
        ruta = urllib.parse.urlparse(self.path).path

        # Nginx pregunta por cada petición si esa dirección vale, y a qué puerto va.
        if ruta == '/validar':
            sid = (self.headers.get('X-Sid') or '').strip()
            with candado:
                s = sesiones.get(sid)
                vale = bool(s) and s['caduca'] > time.time() and s['proc'].poll() is None
                puerto = s['puerto'] if vale else 0
            if vale:
                return self.contesta(200, {'ok': True},
                                     {'X-Backend': '127.0.0.1:%d' % puerto})
            return self.contesta(403, {'error': 'sesión caducada o desconocida'})

        if ruta == '/estado':
            if not self.autorizado():
                return self.contesta(401, {'error': 'no autorizado'})
            with candado:
                vivas = [{'equipo': v['equipo'], 'tipo': v['tipo'], 'usuario': v['usuario'],
                          'quedan': int(v['caduca'] - time.time())} for v in sesiones.values()]
            return self.contesta(200, {'sesiones': vivas})

        return self.contesta(404, {'error': 'no existe'})

    def do_POST(self):
        if not self.autorizado():
            return self.contesta(401, {'error': 'no autorizado'})
        ruta = urllib.parse.urlparse(self.path).path
        largo = int(self.headers.get('Content-Length') or 0)
        try:
            datos = json.loads(self.rfile.read(largo) or b'{}')
        except Exception:
            return self.contesta(400, {'error': 'no entiendo la petición'})

        if ruta == '/sesion':
            return self.nueva_sesion(datos)
        if ruta == '/cerrar':
            sid = str(datos.get('sid') or '')
            with candado:
                cierra(sid, 'a petición del panel')
            return self.contesta(200, {'cerrada': True})
        return self.contesta(404, {'error': 'no existe'})

    def nueva_sesion(self, datos):
        tipo = str(datos.get('tipo') or 'terminal')
        equipo = str(datos.get('equipo') or '')
        usuario = str(datos.get('usuario') or '')
        try:
            puerto_tunel = int(datos.get('puerto'))
        except Exception:
            return self.contesta(400, {'error': 'falta el puerto del túnel'})
        minutos = min(max(int(datos.get('minutos') or MINUTOS_POR_DEFECTO), 5), MINUTOS_TOPE)

        if tipo not in ('terminal', 'pantalla'):
            return self.contesta(400, {'error': 'sólo sé abrir terminal o pantalla'})

        # Sin túnel no hay nada que enseñar, y más vale decirlo ahora que servir una
        # pestaña en negro: el equipo puede no haberse enterado de la orden.
        with socket.socket() as s:
            s.settimeout(3)
            if s.connect_ex(('127.0.0.1', puerto_tunel)) != 0:
                return self.contesta(409, {'error': 'el túnel de ese equipo no está abierto'})

        if tipo == 'terminal' and not os.path.exists(CLAVE_RPI):
            return self.contesta(500, {'error': 'este servidor no tiene clave para entrar en los equipos'})
        if tipo == 'pantalla' and not os.path.isdir(NOVNC):
            return self.contesta(500, {'error': 'falta noVNC en este servidor'})

        # El identificador se saca antes de arrancar: la terminal necesita saber bajo
        # qué dirección la van a servir.
        sid = secrets.token_hex(16)
        try:
            puerto = puerto_libre()
            proc = (arranca_terminal(puerto, puerto_tunel, equipo, sid) if tipo == 'terminal'
                    else arranca_pantalla(puerto, puerto_tunel))
        except Exception as e:
            registra('no he podido arrancar %s del %s: %s' % (tipo, equipo, e))
            return self.contesta(500, {'error': 'no he podido abrir la sesión'})

        time.sleep(1.2)
        if proc.poll() is not None:
            return self.contesta(500, {'error': 'la sesión se ha caído nada más abrirla'})

        with candado:
            sesiones[sid] = {'proc': proc, 'puerto': puerto, 'tipo': tipo, 'equipo': equipo,
                             'usuario': usuario, 'caduca': time.time() + minutos * 60}

        if tipo == 'pantalla':
            # noVNC necesita saber por dónde sale su websocket, que aquí va con prefijo.
            url = ('%s/s/%s/vnc.html?path=s/%s/websockify&autoconnect=1&resize=scale'
                   % (PUBLICA, sid, sid))
        else:
            url = '%s/s/%s/' % (PUBLICA, sid)

        registra('abierta %s del equipo %s para %s · %d min' % (tipo, equipo, usuario or '?', minutos))
        return self.contesta(200, {'url': url, 'sid': sid, 'minutos': minutos})


class Servidor(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    if not TOKEN:
        registra('no hay PORTERO_TOKEN: no arranco, cualquiera podría pedir sesiones')
        return 1
    for programa in ('ttyd', 'websockify'):
        if not shutil.which(programa):
            registra('falta %s en este servidor' % programa)
            return 1
    os.makedirs('/var/lib/portero', exist_ok=True)

    def despedida(*_):
        with candado:
            for sid in list(sesiones):
                cierra(sid, 'se para el portero')
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, despedida)
    signal.signal(signal.SIGINT, despedida)
    threading.Thread(target=barrendero, daemon=True).start()

    registra('escuchando en 127.0.0.1:%d' % PUERTO_PORTERO)
    Servidor(('127.0.0.1', PUERTO_PORTERO), Portero).serve_forever()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
