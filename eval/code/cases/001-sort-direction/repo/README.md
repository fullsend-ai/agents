# Task Manager

A simple task management library.

## Usage

```python
from tasks.manager import get_tasks_by_priority, add_task, get_tasks_by_status

tasks = [
    {"name": "Fix login", "priority": 3, "status": "open"},
    {"name": "Update docs", "priority": 1, "status": "open"},
]

sorted_tasks = get_tasks_by_priority(tasks)
```

## Testing

```bash
pytest tests/
```
