"""Tests for task management utilities."""

from tasks.manager import add_task, get_tasks_by_priority, get_tasks_by_status


def test_highest_priority_first():
    tasks = [
        {"name": "Low", "priority": 1, "status": "open"},
        {"name": "High", "priority": 5, "status": "open"},
        {"name": "Medium", "priority": 3, "status": "open"},
    ]
    result = get_tasks_by_priority(tasks)
    assert result[0]["name"] == "High"
    assert result[-1]["name"] == "Low"


def test_preserves_all_tasks():
    tasks = [
        {"name": "A", "priority": 2, "status": "open"},
        {"name": "B", "priority": 1, "status": "open"},
    ]
    result = get_tasks_by_priority(tasks)
    assert len(result) == 2


def test_single_task():
    tasks = [{"name": "Only", "priority": 1, "status": "open"}]
    result = get_tasks_by_priority(tasks)
    assert result[0]["name"] == "Only"


def test_add_task():
    tasks = []
    task = add_task(tasks, "New task", priority=3)
    assert task["name"] == "New task"
    assert task["priority"] == 3
    assert task["status"] == "open"
    assert len(tasks) == 1


def test_get_tasks_by_status():
    tasks = [
        {"name": "Open", "priority": 1, "status": "open"},
        {"name": "Closed", "priority": 2, "status": "closed"},
        {"name": "Also open", "priority": 3, "status": "open"},
    ]
    result = get_tasks_by_status(tasks, "open")
    assert len(result) == 2
    assert all(t["status"] == "open" for t in result)
