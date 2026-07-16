#!/usr/bin/env bash
# Deploy script — pushes build artifacts to the target server.
set -eo pipefail

BUILD_DIR="${BUILD_DIR:-./build}"

echo "Deploying to ${DEPLOY_TARGET:-}..."
rsync -avz --delete "${BUILD_DIR}/artifacts/" "${DEPLOY_TARGET:-}:/app/"
echo "Deploy complete"
