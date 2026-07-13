#!/usr/bin/env bash
# cross-dedup.src.sh — parent sources nested; src also sources nested directly

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/parent.lib.sh"
source "${SCRIPT_DIR}/lib/nested.lib.sh"

main() {
  parent_fn
}

main "$@"
