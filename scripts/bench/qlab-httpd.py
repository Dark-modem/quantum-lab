#!/usr/bin/env python3
# qlab-httpd.py — minimal fixed-size-object HTTP server for the many-small-
# connections workload. Runs on the receiving host only.
# Usage: qlab-httpd.py <bind-ip> <port> [object-size-bytes]
import http.server
import socketserver
import sys

BIND = sys.argv[1]
PORT = int(sys.argv[2])
SIZE = int(sys.argv[3]) if len(sys.argv) > 3 else 8192
BODY = b"q" * SIZE


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(SIZE))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    Server((BIND, PORT), Handler).serve_forever()
