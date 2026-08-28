"""Minimal HTTP server for the auth service."""

import json
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler

from src.auth.views import login_handler, logout_handler, register_handler

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class Request:
    def __init__(self, params, headers, remote_addr):
        self.params = params
        self.headers = headers
        self.remote_addr = remote_addr
        self.json = None


class AppHandler(BaseHTTPRequestHandler):
    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length:
            return json.loads(self.rfile.read(length))
        return {}

    def _send(self, result):
        if isinstance(result, tuple):
            body, status = result
        else:
            body, status = result, 200
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_POST(self):
        body = self._read_body()
        headers = {k: v for k, v in self.headers.items()}
        req = Request(params=body, headers=headers, remote_addr=self.client_address[0])

        routes = {
            "/login": login_handler,
            "/logout": logout_handler,
            "/register": register_handler,
        }
        handler = routes.get(self.path)
        if handler:
            self._send(handler(req))
        else:
            self._send(({"status": "error", "message": "not found"}, 404))


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8000), AppHandler)
    logger.info("Listening on http://0.0.0.0:8000")
    server.serve_forever()
