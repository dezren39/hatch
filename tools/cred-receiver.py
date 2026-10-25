#!/usr/bin/env python3
"""One-shot credential receiver. Listens on 127.0.0.1 only, single use, then exits.
POST username/password to /submit, or use the form at /.
"""
import http.server
import urllib.parse
import os
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
OUTPUT_FILE = os.path.expanduser("~/.config/nix-cache/r2-presign-creds")
os.makedirs(os.path.dirname(OUTPUT_FILE), exist_ok=True)

FORM = """<!DOCTYPE html>
<html><head><title>Credential Receiver</title></head>
<body style="font-family:sans-serif;max-width:400px;margin:50px auto;">
<h2>R2 S3 Credentials</h2>
<p>One-shot receiver. Server exits after submission.</p>
<form method="POST" action="/submit">
<label>Access Key ID (username):<br>
<input type="text" name="username" style="width:100%" autocomplete="off"></label><br><br>
<label>Secret Access Key (password):<br>
<input type="password" name="password" style="width:100%" autocomplete="off"></label><br><br>
<button type="submit">Submit</button>
</form></body></html>
"""

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(FORM.encode())
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path != "/submit":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode()
        params = urllib.parse.parse_qs(body)
        username = params.get("username", [""])[0]
        password = params.get("password", [""])[0]
        if not username or not password:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"missing username or password")
            return
        # Write with 600 perms
        with open(OUTPUT_FILE, "w") as f:
            os.chmod(OUTPUT_FILE, 0o600)
            f.write(f"R2_ACCESS_KEY_ID={username}\n")
            f.write(f"R2_SECRET_ACCESS_KEY={password}\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"credentials stored. server shutting down.\n")
        # Shutdown after responding
        import threading
        threading.Thread(target=self.server.shutdown, daemon=True).start()

    def log_message(self, *args):
        pass  # quiet

if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"listening on 127.0.0.1:{PORT} (single-use)", flush=True)
    server.serve_forever()
    print("done", flush=True)
