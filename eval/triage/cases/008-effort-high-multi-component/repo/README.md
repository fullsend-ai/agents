# User Service

A Python web application with authentication, user management API,
rate limiting, and session management.

## Architecture

```
src/
  auth/         Session management, validators, login/logout views
  api/          REST endpoints for user CRUD
  middleware/   Auth enforcement, rate limiting
  db/           Data access layer
tests/          Unit tests
```

## Running

```bash
pip install -r requirements.txt
python -m src.main
```

## Configuration

Environment variables:

- `SESSION_TTL` — session timeout in seconds (default: 3600)
- `RATE_LIMIT_WINDOW` — rate limit window in seconds (default: 60)
- `RATE_LIMIT_MAX` — max requests per window (default: 100)
- `LOG_LEVEL` — logging verbosity (default: INFO)
