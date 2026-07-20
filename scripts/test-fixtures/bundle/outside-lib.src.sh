#!/usr/bin/env bash
# outside-lib.src.sh — must fail bundling (source outside scripts/lib)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../bundle-sh.sh"

main() {
  echo "should not run"
}

main "$@"
