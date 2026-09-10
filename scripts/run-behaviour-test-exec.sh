#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 TEST-BINARY [ARGS...]" >&2
  exit 2
fi

test_binary="$1"
shift

# go test may provide a relative test-binary path. Resolve it before changing
# directories so the binary remains addressable from the fullsend checkout.
if [[ "$test_binary" != /* ]]; then
  test_binary="$PWD/$test_binary"
fi

if [[ -n "${FULLSEND_CHECKOUT:-}" ]]; then
  script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
  agent_checkout="$(cd -- "$script_dir/.." && pwd)"
  fixture_link="$FULLSEND_CHECKOUT/behaviour"
  if [[ -e "$fixture_link" || -L "$fixture_link" ]]; then
    echo "fullsend checkout already contains $fixture_link" >&2
    exit 1
  fi
  ln -s "$agent_checkout/behaviour" "$fixture_link"
  trap 'rm -f "$fixture_link"' EXIT
  cd "$FULLSEND_CHECKOUT"
fi

"$test_binary" "$@"
