#!/usr/bin/env bash
# comment.src.sh — quoted source path with trailing inline comment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/test-fixtures/leaf.lib.sh" # inline comment

main() {
  leaf_fn
}

main "$@"
