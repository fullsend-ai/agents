#!/usr/bin/env bash
# dedup.src.sh — duplicate source lines should inline once

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/test-fixtures/leaf.lib.sh"
source "${SCRIPT_DIR}/../../lib/test-fixtures/leaf.lib.sh"

main() {
  leaf_fn
}

main "$@"
