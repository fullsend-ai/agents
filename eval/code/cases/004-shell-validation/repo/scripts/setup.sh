#!/usr/bin/env bash
# Setup script — prepares the build environment.
set -euo pipefail

# Validate required environment variables
for var in BUILD_DIR APP_NAME; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is not set" >&2
    exit 1
  fi
done

echo "Setting up build environment..."
mkdir -p "${BUILD_DIR}/artifacts"
echo "Build environment ready for ${APP_NAME}"
