import socket, threading, select
def pipe(a, b):
    try:
        while True:
            r, _, _ = select.select([a], [], [], 30)
            if not r: break
            data = a.recv(65536)
            if not data: break
            b.sendall(data)
    except OSError: pass
    finally:
        try: b.shutdown(socket.SHUT_RDWR)
        except OSError: pass
def handle(client):
    try:
        client.settimeout(15)
        buf = b''
        while b'\r\n\r\n' not in buf:
            chunk = client.recv(4096)
            if not chunk: client.close(); return
            buf += chunk
        first = buf.split(b'\r\n')[0].decode(errors='replace')
        if not first.startswith('CONNECT'):
            client.sendall(b'HTTP/1.1 405 Method Not Allowed\r\n\r\n'); client.close(); return
        up = socket.create_connection(('198.19.0.1', 3128), timeout=10)
        up.sendall(buf)
        threading.Thread(target=pipe, args=(up, client), daemon=True).start()
        pipe(client, up)
    except OSError:
        try: client.close()
        except OSError: pass
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', 18081)); srv.listen(50)
print('relay listening', flush=True)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
