#!/usr/bin/env bash
# nested.src.sh — nested lib bundle fixture

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/parent.lib.sh"

main() {
  parent_fn
}

main "$@"
