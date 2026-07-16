#!/usr/bin/env bash
# Rollback script — restores the previous deployment.
set -euo pipefail

for var in DEPLOY_TARGET BACKUP_DIR; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is not set" >&2
    exit 1
  fi
done

echo "Rolling back ${DEPLOY_TARGET} from ${BACKUP_DIR}..."
rsync -avz --delete "${BACKUP_DIR}/" "${DEPLOY_TARGET}:/app/"
echo "Rollback complete"
