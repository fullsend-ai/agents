"""WSGI entry point."""

import json

from .http.request import Request
from .users.views import list_users


def app(environ, start_response):
    request = Request(environ)
    if request.method == "GET" and request.path == "/api/users":
        body = list_users(request)
        start_response("200 OK", [("Content-Type", "application/json")])
        return [json.dumps(body).encode()]
    start_response("404 Not Found", [("Content-Type", "text/plain")])
    return [b"not found"]
