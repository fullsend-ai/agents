.PHONY: test lint

test:
	pytest tests/ -v

lint:
	python -m py_compile formatters/api_handler.py
	python -m py_compile formatters/webhook_handler.py
