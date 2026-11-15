"""WSGI entry point."""

import json

from .auth.views import login_handler
from .http.request import Request


def app(environ, start_response):
    request = Request(environ)
    if request.path == "/login":
        body = login_handler(request)
        start_response("200 OK", [("Content-Type", "application/json")])
        return [json.dumps(body).encode()]
    start_response("404 Not Found", [("Content-Type", "text/plain")])
    return [b"not found"]
