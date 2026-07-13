#!/usr/bin/env bash
# simple.src.sh — single-lib bundle fixture

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/test-fixtures/leaf.lib.sh"

main() {
  leaf_fn
}

main "$@"
