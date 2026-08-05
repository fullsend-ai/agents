"""Minimal HTTP server for the auth + user management service."""

import json
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler

from src.auth.views import login_handler, logout_handler, session_status_handler
from src.api.users import list_users, get_user, update_user_handler, delete_user_handler
from src.middleware.rate_limit import check_rate_limit

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class Request:
    def __init__(self, params, headers, remote_addr, body_json=None):
        self.params = params
        self.headers = headers
        self.remote_addr = remote_addr
        self.json = body_json
        self.user_id = None


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

    def _make_request(self, body=None):
        headers = {k: v for k, v in self.headers.items()}
        return Request(
            params=body or {},
            headers=headers,
            remote_addr=self.client_address[0],
            body_json=body,
        )

    def _rate_limited(self):
        if not check_rate_limit(self.client_address[0]):
            self._send(({"status": "error", "message": "rate limit exceeded"}, 429))
            return True
        return False

    def _user_id_from_path(self):
        parts = self.path.strip("/").split("/")
        if len(parts) >= 2:
            return parts[1]
        return None

    def do_POST(self):
        if self._rate_limited():
            return
        body = self._read_body()
        req = self._make_request(body)
        if self.path == "/login":
            self._send(login_handler(req))
        elif self.path == "/logout":
            self._send(logout_handler(req))
        else:
            self._send(({"status": "error", "message": "not found"}, 404))

    def do_GET(self):
        if self._rate_limited():
            return
        req = self._make_request()
        if self.path == "/session":
            self._send(session_status_handler(req))
        elif self.path == "/users":
            self._send(list_users(req))
        elif self.path.startswith("/users/"):
            self._send(get_user(req, self._user_id_from_path()))
        else:
            self._send(({"status": "error", "message": "not found"}, 404))

    def do_PUT(self):
        if self._rate_limited():
            return
        body = self._read_body()
        req = self._make_request(body)
        if self.path.startswith("/users/"):
            self._send(update_user_handler(req, self._user_id_from_path()))
        else:
            self._send(({"status": "error", "message": "not found"}, 404))

    def do_DELETE(self):
        if self._rate_limited():
            return
        req = self._make_request()
        if self.path.startswith("/users/"):
            self._send(delete_user_handler(req, self._user_id_from_path()))
        else:
            self._send(({"status": "error", "message": "not found"}, 404))


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8000), AppHandler)
    logger.info("Listening on http://0.0.0.0:8000")
    server.serve_forever()
