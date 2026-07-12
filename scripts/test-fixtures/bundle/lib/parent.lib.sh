#!/usr/bin/env bash
# parent.lib.sh — parent library that sources nested.lib.sh

[[ -n "${PARENT_LIB_LOADED:-}" ]] && return 0
PARENT_LIB_LOADED=1

source "${SCRIPT_DIR}/lib/nested.lib.sh"

parent_fn() {
  nested_fn
}
