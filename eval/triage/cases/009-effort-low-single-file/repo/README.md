# Auth Service

A Python authentication service with email validation, password
verification, and login/logout endpoints.

## Running

```bash
pip install -r requirements.txt
python -m src.main
```

## API

| Method | Path        | Description              |
|--------|-------------|--------------------------|
| POST   | `/login`    | Authenticate with email and password |
| POST   | `/logout`   | End the current session  |
| POST   | `/register` | Create a new account     |

## Testing

```bash
pytest tests/
```
