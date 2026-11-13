#!/usr/bin/env bash
# shellcheck disable=SC2317  # test functions are reachable via run_test
# harness-config-lint-test.sh — Test harness config structural invariants.
#
# Validates that all harness/*.yaml files follow consistent patterns:
# - Every validation_loop with a script key must have a schema key
# - No env.runner block contains FULLSEND_OUTPUT_SCHEMA
# - Each referenced schema file exists and is valid JSON
#
# Run from the repo root:
#   bash scripts/harness-config-lint-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/harness"
FAILURES=0

run_test() {
  local test_name="$1"
  shift
  local output
  local exit_code=0
  output="$("$@" 2>&1)" || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name}"
    if [[ -n "${output}" ]]; then
      echo "  ${output}"
    fi
    FAILURES=$((FAILURES + 1))
  fi
}

# Test 1: Every validation_loop with script must have schema
test_validation_loop_schema() {
  local found_error=0
  for harness in "${HARNESS_DIR}"/*.yaml; do
    local harness_name
    harness_name="$(basename "${harness}")"

    local has_validation_loop
    local has_script
    local has_schema
    local schema_value

    has_validation_loop="$(yq eval 'has("validation_loop")' "${harness}" 2>/dev/null)" || has_validation_loop="false"
    if [[ "${has_validation_loop}" != "true" ]]; then
      continue
    fi

    has_script="$(yq eval '.validation_loop | has("script")' "${harness}" 2>/dev/null)" || has_script="false"
    if [[ "${has_script}" != "true" ]]; then
      continue
    fi

    has_schema="$(yq eval '.validation_loop | has("schema")' "${harness}" 2>/dev/null)" || has_schema="false"
    if [[ "${has_schema}" != "true" ]]; then
      echo "${harness_name}: validation_loop has script but no schema"
      found_error=1
      continue
    fi

    schema_value="$(yq eval '.validation_loop.schema' "${harness}" 2>/dev/null)" || schema_value=""
    if [[ -z "${schema_value}" || "${schema_value}" == "null" ]]; then
      echo "${harness_name}: validation_loop.schema is empty or null"
      found_error=1
    fi
  done
  return ${found_error}
}

# Test 2: No env.runner contains FULLSEND_OUTPUT_SCHEMA
test_no_hardcoded_schema() {
  local found_hardcoded=0
  for harness in "${HARNESS_DIR}"/*.yaml; do
    local harness_name
    harness_name="$(basename "${harness}")"

    local env_runner_schema
    env_runner_schema="$(yq eval '.env.runner.FULLSEND_OUTPUT_SCHEMA' "${harness}" 2>/dev/null)" || env_runner_schema="null"
    if [[ "${env_runner_schema}" != "null" ]] && [[ -n "${env_runner_schema}" ]]; then
      echo "${harness_name}: env.runner contains hardcoded FULLSEND_OUTPUT_SCHEMA (should be declared in validation_loop.schema)"
      found_hardcoded=1
    fi

    local platforms
    platforms="$(yq eval '.forge | keys | .[]' "${harness}" 2>/dev/null)"
    while IFS= read -r platform; do
      [[ -z "${platform}" ]] && continue
      local forge_env_schema
      forge_env_schema="$(yq eval ".forge.${platform}.env.runner.FULLSEND_OUTPUT_SCHEMA" "${harness}" 2>/dev/null)" || forge_env_schema="null"
      if [[ "${forge_env_schema}" != "null" ]] && [[ -n "${forge_env_schema}" ]]; then
        echo "${harness_name}: forge.${platform}.env.runner contains hardcoded FULLSEND_OUTPUT_SCHEMA"
        found_hardcoded=1
      fi
    done <<< "${platforms}"
  done

  return ${found_hardcoded}
}

# Test 3: All referenced schemas exist and are valid JSON
test_schema_files_exist_and_valid() {
  local found_error=0
  for harness in "${HARNESS_DIR}"/*.yaml; do
    local harness_name
    harness_name="$(basename "${harness}")"

    local has_validation_loop
    has_validation_loop="$(yq eval 'has("validation_loop")' "${harness}" 2>/dev/null)" || has_validation_loop="false"
    if [[ "${has_validation_loop}" != "true" ]]; then
      continue
    fi

    local has_schema
    has_schema="$(yq eval '.validation_loop | has("schema")' "${harness}" 2>/dev/null)" || has_schema="false"
    if [[ "${has_schema}" != "true" ]]; then
      continue
    fi

    local schema_path
    schema_path="$(yq eval '.validation_loop.schema' "${harness}" 2>/dev/null)" || schema_path=""
    if [[ -z "${schema_path}" ]]; then
      continue
    fi

    local full_schema_path
    full_schema_path="${REPO_ROOT}/${schema_path}"

    if [[ ! -f "${full_schema_path}" ]]; then
      echo "${harness_name}: schema file not found: ${schema_path}"
      found_error=1
      continue
    fi

    if ! jq -s -e 'length == 1' "${full_schema_path}" 2>/dev/null; then
      echo "${harness_name}: schema file is not valid JSON (must be exactly one JSON document): ${schema_path}"
      found_error=1
    fi
  done

  if [[ ${found_error} -eq 0 ]]; then
    return 0
  else
    return 1
  fi
}

# Test 4: All harness files are valid YAML
test_harness_yaml_valid() {
  local found_error=0
  for harness in "${HARNESS_DIR}"/*.yaml; do
    local harness_name
    harness_name="$(basename "${harness}")"

    if ! yq eval 'keys' "${harness}" > /dev/null 2>&1; then
      echo "${harness_name}: invalid YAML syntax"
      found_error=1
    fi
  done

  if [[ ${found_error} -eq 0 ]]; then
    return 0
  else
    return 1
  fi
}

run_test "harness-yaml-valid" test_harness_yaml_valid
run_test "validation-loop-has-schema" test_validation_loop_schema
run_test "no-hardcoded-schema-in-env" test_no_hardcoded_schema
run_test "schema-files-exist-and-valid" test_schema_files_exist_and_valid

if [[ ${FAILURES} -eq 0 ]]; then
  echo
  echo "✓ All harness config invariants pass"
  exit 0
else
  echo
  echo "✗ ${FAILURES} test(s) failed"
  exit 1
fi
