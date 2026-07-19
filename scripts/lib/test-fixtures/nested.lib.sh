#!/usr/bin/env bash
# nested.lib.sh — nested library fixture for bundle-sh-test.sh

[[ -n "${NESTED_LIB_LOADED:-}" ]] && return 0
NESTED_LIB_LOADED=1

nested_fn() {
  echo "nested"
}
