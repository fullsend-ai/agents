"""Minimal request object built from the raw WSGI environ."""

from urllib.parse import parse_qsl


class Request:
    def __init__(self, environ):
        self.method = environ.get("REQUEST_METHOD", "GET")
        self.path = environ.get("PATH_INFO", "/")
        # parse_qsl decodes form encoding, where "+" means a space.
        self.params = dict(parse_qsl(environ.get("QUERY_STRING", "")))
