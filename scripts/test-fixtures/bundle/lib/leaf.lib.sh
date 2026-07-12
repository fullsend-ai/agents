#!/usr/bin/env bash
# leaf.lib.sh — leaf library fixture for bundle-sh-test.sh

[[ -n "${LEAF_LIB_LOADED:-}" ]] && return 0
LEAF_LIB_LOADED=1

leaf_fn() {
  echo "leaf"
}
