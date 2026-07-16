"""Task management utilities."""


def get_tasks_by_priority(tasks):
    """Return tasks sorted by priority (highest first)."""
    return sorted(tasks, key=lambda t: t["priority"])


def add_task(tasks, name, priority=1, status="open"):
    """Add a new task to the list."""
    task = {"name": name, "priority": priority, "status": status}
    tasks.append(task)
    return task


def get_tasks_by_status(tasks, status):
    """Return tasks matching the given status."""
    return [t for t in tasks if t["status"] == status]
