# Agent Guidelines

This document describes conventions for contributing to the
notification service.

## Project Structure

- `cmd/server/` — HTTP server entry point
- `internal/notify/` — Core notification logic
- `internal/notify/notify_test.go` — Tests

## Code Style

- Use `gofmt` for formatting — do not override with custom rules
- Prefer returning errors over panicking
- Keep functions under 40 lines; extract helpers when they grow
- Name variables descriptively: `userEmail` not `ue`

## Testing

- Every exported function must have at least one test
- Use table-driven tests for functions with multiple input variations
- Run `make test` before committing

## Commit Messages

- Use conventional commit format: `feat:`, `fix:`, `docs:`, `test:`
- Reference the issue number in the body, not the subject line
- Keep subject under 72 characters
