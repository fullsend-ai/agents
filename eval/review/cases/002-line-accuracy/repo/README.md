# event-analytics

Event processing and analytics utilities.

## Usage

```python
from src.analytics import Event
from datetime import datetime

e = Event("click", datetime.now(), 1.0)
```

## Testing

```bash
python -m pytest tests/
```
