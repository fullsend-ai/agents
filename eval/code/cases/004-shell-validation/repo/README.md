# Deploy Toolkit

Scripts for building, deploying, and rolling back the application.

## Scripts

- `scripts/setup.sh` — Prepare the build environment
- `scripts/deploy.sh` — Deploy artifacts to target server
- `scripts/rollback.sh` — Rollback to previous deployment

## Required Environment Variables

| Variable | Used by | Description |
|----------|---------|-------------|
| `BUILD_DIR` | setup.sh, deploy.sh | Path to build output directory |
| `APP_NAME` | setup.sh | Application name |
| `DEPLOY_TARGET` | deploy.sh, rollback.sh | Target server hostname |
| `BACKUP_DIR` | rollback.sh | Path to backup directory |

## Testing

```bash
make test   # validate env var checks
make lint   # shellcheck
```
