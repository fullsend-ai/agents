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
HARNESS_DIR="${HARNESS_DIR:-${REPO_ROOT}/harness}"
FAILURES=0

# Check for required tools at startup
if ! command -v yq &>/dev/null; then
  echo "ERROR: yq (mikefarah/yq) is required but not found in PATH" >&2
  exit 1
fi
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not found in PATH" >&2
  exit 1
fi

# Verify yq is the mikefarah version (not the python kiss lyuk version)
YQ_VERSION=$(yq --version 2>&1)
if ! echo "${YQ_VERSION}" | grep -q "mikefarah\|yq version 4"; then
  echo "ERROR: yq must be mikefarah version (yq v4+), got: ${YQ_VERSION}" >&2
  exit 1
fi

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

# Helper: check validation_loop at a given path
# Top-level: require schema if script is present
# Per-location (forge/overlay): only require schema if script is explicitly overridden (different from top-level)
check_validation_loop_at_path() {
  local harness="$1"
  local path="$2"
  local location="${3:-.}"
  local top_level_script="${4:-}"
  local harness_name
  harness_name="$(basename "${harness}")"

  local selector
  if [[ "${path}" == "." ]]; then
    selector="has(\"validation_loop\")"
  else
    selector="${path} | has(\"validation_loop\")"
  fi

  local has_validation_loop
  has_validation_loop="$(yq "${selector}" "${harness}")" || {
    echo "${harness_name}: yq failed to check validation_loop at ${location}"
    return 1
  }
  if [[ "${has_validation_loop}" != "true" ]]; then
    return 0
  fi

  local has_script
  if [[ "${path}" == "." ]]; then
    has_script="$(yq ".validation_loop | has(\"script\")" "${harness}")" || {
      echo "${harness_name}: yq failed to check script at ${location}"
      return 1
    }
  else
    has_script="$(yq "${path}.validation_loop | has(\"script\")" "${harness}")" || {
      echo "${harness_name}: yq failed to check script at ${location}"
      return 1
    }
  fi
  if [[ "${has_script}" != "true" ]]; then
    return 0
  fi

  # For per-location blocks, allow inheritance only when applicable inherited schema exists
  if [[ "${path}" != "." ]]; then
    local per_location_script
    per_location_script="$(yq "${path}.validation_loop.script" "${harness}")" || {
      echo "${harness_name}: yq failed to extract script at ${location}"
      return 1
    }
    local per_location_schema
    per_location_schema="$(yq "${path}.validation_loop.schema" "${harness}")" || {
      echo "${harness_name}: yq failed to extract schema at ${location}"
      return 1
    }
    # Allow inheritance only when schema is empty/null AND there is a top-level schema
    if [[ -z "${per_location_schema}" || "${per_location_schema}" == "null" ]]; then
      # Check if top-level schema exists
      local top_level_has_schema
      top_level_has_schema="$(yq '.validation_loop | has("schema")' "${harness}")" || {
        echo "${harness_name}: yq failed to check top-level schema"
        return 1
      }
      if [[ "${top_level_has_schema}" == "true" ]]; then
        return 0
      else
        echo "${harness_name}: ${location} validation_loop has script but no schema (and no top-level schema to inherit)"
        return 1
      fi
    fi
    # Also allow inheritance when script matches top-level (both script and schema inherited)
    if [[ -n "${top_level_script}" && "${per_location_script}" == "${top_level_script}" ]]; then
      return 0
    fi
  fi

  local has_schema
  if [[ "${path}" == "." ]]; then
    has_schema="$(yq ".validation_loop | has(\"schema\")" "${harness}")" || {
      echo "${harness_name}: yq failed to check schema at ${location}"
      return 1
    }
  else
    has_schema="$(yq "${path}.validation_loop | has(\"schema\")" "${harness}")" || {
      echo "${harness_name}: yq failed to check schema at ${location}"
      return 1
    }
  fi
  if [[ "${has_schema}" != "true" ]]; then
    echo "${harness_name}: ${location} validation_loop has script but no schema"
    return 1
  fi

  local schema_value
  if [[ "${path}" == "." ]]; then
    schema_value="$(yq ".validation_loop.schema" "${harness}")" || {
      echo "${harness_name}: yq failed to extract schema at ${location}"
      return 1
    }
  else
    schema_value="$(yq "${path}.validation_loop.schema" "${harness}")" || {
      echo "${harness_name}: yq failed to extract schema at ${location}"
      return 1
    }
  fi
  if [[ -z "${schema_value}" || "${schema_value}" == "null" ]]; then
    echo "${harness_name}: ${location} validation_loop.schema is empty or null"
    return 1
  fi

  return 0
}

# Test 1: Every validation_loop with script must have schema
test_validation_loop_schema() {
  local found_error=0
  local file_count=0
  for harness in "${HARNESS_DIR}"/*.yaml "${REPO_ROOT}"/examples/*/harness/*.yaml "${REPO_ROOT}"/eval/harness/*.yaml; do
    [[ -f "${harness}" ]] || continue
    file_count=$((file_count + 1))
    local harness_name
    harness_name="$(basename "${harness}")"

    # Check top-level validation_loop
    check_validation_loop_at_path "${harness}" "." "top-level" || found_error=1

    # Extract top-level script for comparison with per-location blocks
    local top_level_script=""
    local has_top_level_validation_loop
    has_top_level_validation_loop="$(yq 'has("validation_loop")' "${harness}")" || {
      echo "${harness_name}: yq failed to check has validation_loop"
      found_error=1
      continue
    }
    if [[ "${has_top_level_validation_loop}" == "true" ]]; then
      local has_top_level_script
      has_top_level_script="$(yq '.validation_loop | has("script")' "${harness}")" || {
        echo "${harness_name}: yq failed to check top-level script"
        found_error=1
        continue
      }
      if [[ "${has_top_level_script}" == "true" ]]; then
        top_level_script="$(yq '.validation_loop.script' "${harness}")" || {
          echo "${harness_name}: yq failed to extract top-level script"
          found_error=1
          continue
        }
      fi
    fi

    # Check forge-specific validation_loops
    local has_forge
    has_forge="$(yq 'has("forge")' "${harness}")" || {
      echo "${harness_name}: yq failed to check forge"
      found_error=1
      continue
    }
    if [[ "${has_forge}" == "true" ]]; then
      local platforms
      platforms="$(yq '.forge | keys | .[]' "${harness}")" || {
        echo "${harness_name}: yq failed to get forge keys"
        found_error=1
        continue
      }
      while IFS= read -r platform; do
        [[ -z "${platform}" ]] && continue
        check_validation_loop_at_path "${harness}" ".forge.${platform}" "forge.${platform}" "${top_level_script}" || found_error=1
      done <<< "${platforms}"
    fi

    # Check overlay validation_loops
    local overlay_count
    overlay_count="$(yq '.overlays | length' "${harness}")" || {
      echo "${harness_name}: yq failed to get overlay count"
      found_error=1
      continue
    }
    if [[ ${overlay_count} -gt 0 ]]; then
      local i
      for ((i=0; i<overlay_count; i++)); do
        check_validation_loop_at_path "${harness}" ".overlays[${i}]" "overlays[${i}]" "${top_level_script}" || found_error=1
      done
    fi
  done
  if [[ ${file_count} -eq 0 ]]; then
    echo "no harness files found in ${HARNESS_DIR}, examples, or eval/harness"
    return 1
  fi
  if [[ ${found_error} -eq 0 ]]; then
    return 0
  else
    return 1
  fi
}

# Test 2: No env.runner or runner_env contains FULLSEND_OUTPUT_SCHEMA
test_no_hardcoded_schema() {
  local found_hardcoded=0
  for harness in "${HARNESS_DIR}"/*.yaml "${REPO_ROOT}"/examples/*/harness/*.yaml "${REPO_ROOT}"/eval/harness/*.yaml; do
    [[ -f "${harness}" ]] || continue
    local harness_name
    harness_name="$(basename "${harness}")"

    local has_top_schema
    has_top_schema="$(yq '.env.runner | has("FULLSEND_OUTPUT_SCHEMA")' "${harness}")" || {
      echo "${harness_name}: yq failed to check env.runner"
      found_hardcoded=1
      continue
    }
    if [[ "${has_top_schema}" == "true" ]]; then
      echo "${harness_name}: env.runner contains hardcoded FULLSEND_OUTPUT_SCHEMA"
      found_hardcoded=1
    fi

    local has_top_runner_env
    has_top_runner_env="$(yq '.runner_env | has("FULLSEND_OUTPUT_SCHEMA")' "${harness}")" || {
      echo "${harness_name}: yq failed to check runner_env"
      found_hardcoded=1
      continue
    }
    if [[ "${has_top_runner_env}" == "true" ]]; then
      echo "${harness_name}: runner_env (deprecated) contains hardcoded FULLSEND_OUTPUT_SCHEMA"
      found_hardcoded=1
    fi

    local has_forge
    has_forge="$(yq 'has("forge")' "${harness}")" || {
      echo "${harness_name}: yq failed to check forge"
      found_hardcoded=1
      continue
    }
    if [[ "${has_forge}" == "true" ]]; then
      local platforms
      platforms="$(yq '.forge | keys | .[]' "${harness}")" || {
        echo "${harness_name}: yq failed to get forge keys"
        found_hardcoded=1
        continue
      }
      while IFS= read -r platform; do
        [[ -z "${platform}" ]] && continue
        local has_forge_schema
        has_forge_schema="$(yq ".forge.${platform}.env.runner | has(\"FULLSEND_OUTPUT_SCHEMA\")" "${harness}")" || {
          echo "${harness_name}: yq failed to check forge.${platform}.env.runner"
          found_hardcoded=1
          continue
        }
        if [[ "${has_forge_schema}" == "true" ]]; then
          echo "${harness_name}: forge.${platform}.env.runner contains hardcoded FULLSEND_OUTPUT_SCHEMA"
          found_hardcoded=1
        fi

        local has_forge_runner_env
        has_forge_runner_env="$(yq ".forge.${platform}.runner_env | has(\"FULLSEND_OUTPUT_SCHEMA\")" "${harness}")" || {
          echo "${harness_name}: yq failed to check forge.${platform}.runner_env"
          found_hardcoded=1
          continue
        }
        if [[ "${has_forge_runner_env}" == "true" ]]; then
          echo "${harness_name}: forge.${platform}.runner_env (deprecated) contains hardcoded FULLSEND_OUTPUT_SCHEMA"
          found_hardcoded=1
        fi
      done <<< "${platforms}"
    fi

    local overlay_count
    overlay_count="$(yq '.overlays | length' "${harness}")" || {
      echo "${harness_name}: yq failed to get overlay count"
      found_hardcoded=1
      continue
    }
    if [[ ${overlay_count} -gt 0 ]]; then
      local i
      for ((i=0; i<overlay_count; i++)); do
        local has_overlay_env_runner
        has_overlay_env_runner="$(yq ".overlays[${i}].env.runner | has(\"FULLSEND_OUTPUT_SCHEMA\")" "${harness}")" || {
          echo "${harness_name}: yq failed to check overlays[${i}].env.runner"
          found_hardcoded=1
          continue
        }
        if [[ "${has_overlay_env_runner}" == "true" ]]; then
          echo "${harness_name}: overlays[${i}].env.runner contains hardcoded FULLSEND_OUTPUT_SCHEMA"
          found_hardcoded=1
        fi

        local has_overlay_runner_env
        has_overlay_runner_env="$(yq ".overlays[${i}].runner_env | has(\"FULLSEND_OUTPUT_SCHEMA\")" "${harness}")" || {
          echo "${harness_name}: yq failed to check overlays[${i}].runner_env"
          found_hardcoded=1
          continue
        }
        if [[ "${has_overlay_runner_env}" == "true" ]]; then
          echo "${harness_name}: overlays[${i}].runner_env (deprecated) contains hardcoded FULLSEND_OUTPUT_SCHEMA"
          found_hardcoded=1
        fi
      done
    fi
  done

  if [[ ${found_hardcoded} -eq 0 ]]; then
    return 0
  else
    return 1
  fi
}

# Helper: check schema file existence at a given validation_loop path
# Resolves schema paths relative to the provided resolve_root (matching engine's ResolveRelativeTo)
check_schema_files_at_path() {
  local harness="$1"
  local path="$2"
  local location="${3:-.}"
  local resolve_root="$4"
  local harness_name
  harness_name="$(basename "${harness}")"

  local has_validation_loop_selector
  if [[ "${path}" == "." ]]; then
    has_validation_loop_selector="has(\"validation_loop\")"
  else
    has_validation_loop_selector="${path} | has(\"validation_loop\")"
  fi

  local has_validation_loop
  has_validation_loop="$(yq "${has_validation_loop_selector}" "${harness}")" || {
    echo "${harness_name}: yq failed to check validation_loop at ${location}"
    return 1
  }
  if [[ "${has_validation_loop}" != "true" ]]; then
    return 0
  fi

  local has_schema_selector
  if [[ "${path}" == "." ]]; then
    has_schema_selector=".validation_loop | has(\"schema\")"
  else
    has_schema_selector="${path}.validation_loop | has(\"schema\")"
  fi

  local has_schema
  has_schema="$(yq "${has_schema_selector}" "${harness}")" || {
    echo "${harness_name}: yq failed to check schema at ${location}"
    return 1
  }
  if [[ "${has_schema}" != "true" ]]; then
    return 0
  fi

  local schema_selector
  if [[ "${path}" == "." ]]; then
    schema_selector=".validation_loop.schema"
  else
    schema_selector="${path}.validation_loop.schema"
  fi

  local schema_path
  schema_path="$(yq "${schema_selector}" "${harness}")" || {
    echo "${harness_name}: yq failed to extract schema path at ${location}"
    return 1
  }
  # Skip if schema is empty or null (inherited schema will be checked separately)
  if [[ -z "${schema_path}" || "${schema_path}" == "null" ]]; then
    return 0
  fi

  # Resolve relative to the provided root (matching engine's ResolveRelativeTo)
  # If no root provided, fall back to dirname(dirname(harness)) for backwards compatibility
  local resolve_dir="${resolve_root}"
  if [[ -z "${resolve_dir}" ]]; then
    resolve_dir="$(dirname "$(dirname "${harness}")")"
  fi
  local full_schema_path
  full_schema_path="${resolve_dir}/${schema_path}"

  if [[ ! -f "${full_schema_path}" ]]; then
    echo "${harness_name}: ${location} schema file not found: ${schema_path}"
    return 1
  fi

  if ! jq -s -e 'length == 1' "${full_schema_path}"; then
    echo "${harness_name}: ${location} schema file is not valid JSON: ${schema_path}"
    return 1
  fi

  return 0
}

# Test 3: All referenced schemas exist and are valid JSON
test_schema_files_exist_and_valid() {
  local found_error=0
  local file_count=0

  # Process harness/ and eval/harness/ with REPO_ROOT as resolve root
  for harness in "${HARNESS_DIR}"/*.yaml "${REPO_ROOT}"/eval/harness/*.yaml; do
    [[ -f "${harness}" ]] || continue
    file_count=$((file_count + 1))
    local harness_name
    harness_name="$(basename "${harness}")"

    # Check top-level schema
    check_schema_files_at_path "${harness}" "." "top-level" "${REPO_ROOT}" || found_error=1

    # Check forge-specific schemas
    local has_forge
    has_forge="$(yq 'has("forge")' "${harness}")" || {
      echo "${harness_name}: yq failed to check forge"
      found_error=1
      continue
    }
    if [[ "${has_forge}" == "true" ]]; then
      local platforms
      platforms="$(yq '.forge | keys | .[]' "${harness}")" || {
        echo "${harness_name}: yq failed to get forge keys"
        found_error=1
        continue
      }
      while IFS= read -r platform; do
        [[ -z "${platform}" ]] && continue
        check_schema_files_at_path "${harness}" ".forge.${platform}" "forge.${platform}" "${REPO_ROOT}" || found_error=1
      done <<< "${platforms}"
    fi

    # Check overlay schemas
    local overlay_count
    overlay_count="$(yq '.overlays | length' "${harness}")" || {
      echo "${harness_name}: yq failed to get overlay count"
      found_error=1
      continue
    }
    if [[ ${overlay_count} -gt 0 ]]; then
      local i
      for ((i=0; i<overlay_count; i++)); do
        check_schema_files_at_path "${harness}" ".overlays[${i}]" "overlays[${i}]" "${REPO_ROOT}" || found_error=1
      done
    fi
  done

  # Process examples/*/harness/ with dirname(dirname(harness)) as resolve root
  for harness in "${REPO_ROOT}"/examples/*/harness/*.yaml; do
    [[ -f "${harness}" ]] || continue
    file_count=$((file_count + 1))
    local harness_name
    harness_name="$(basename "${harness}")"
    local resolve_root
    resolve_root="$(dirname "$(dirname "${harness}")")"

    # Check top-level schema
    check_schema_files_at_path "${harness}" "." "top-level" "${resolve_root}" || found_error=1

    # Check forge-specific schemas
    local has_forge
    has_forge="$(yq 'has("forge")' "${harness}")" || {
      echo "${harness_name}: yq failed to check forge"
      found_error=1
      continue
    }
    if [[ "${has_forge}" == "true" ]]; then
      local platforms
      platforms="$(yq '.forge | keys | .[]' "${harness}")" || {
        echo "${harness_name}: yq failed to get forge keys"
        found_error=1
        continue
      }
      while IFS= read -r platform; do
        [[ -z "${platform}" ]] && continue
        check_schema_files_at_path "${harness}" ".forge.${platform}" "forge.${platform}" "${resolve_root}" || found_error=1
      done <<< "${platforms}"
    fi

    # Check overlay schemas
    local overlay_count
    overlay_count="$(yq '.overlays | length' "${harness}")" || {
      echo "${harness_name}: yq failed to get overlay count"
      found_error=1
      continue
    }
    if [[ ${overlay_count} -gt 0 ]]; then
      local i
      for ((i=0; i<overlay_count; i++)); do
        check_schema_files_at_path "${harness}" ".overlays[${i}]" "overlays[${i}]" "${resolve_root}" || found_error=1
      done
    fi
  done

  if [[ ${file_count} -eq 0 ]]; then
    echo "no harness files found in ${HARNESS_DIR}, examples, or eval/harness"
    return 1
  fi

  if [[ ${found_error} -eq 0 ]]; then
    return 0
  else
    return 1
  fi
}

# Test 4: All harness files are valid YAML
test_harness_yaml_valid() {
  local found_error=0
  for harness in "${HARNESS_DIR}"/*.yaml "${REPO_ROOT}"/examples/*/harness/*.yaml "${REPO_ROOT}"/eval/harness/*.yaml; do
    [[ -f "${harness}" ]] || continue
    local harness_name
    harness_name="$(basename "${harness}")"

    if ! yq 'keys' "${harness}" > /dev/null 2>&1; then
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

# Test 5: Verify negative fixtures fail (prove the checks can detect errors)
test_negative_fixtures() {
  local found_error=0
  local fixtures_dir="${SCRIPT_DIR}/test-fixtures/harness-config-bad"

  if [[ ! -d "${fixtures_dir}" ]]; then
    echo "fixtures directory not found: ${fixtures_dir}"
    return 1
  fi

  local expected_failures=(
    "script-no-schema.yaml:test_validation_loop_schema:^script-no-schema.yaml.*top-level validation_loop has script but no schema"
    "empty-schema.yaml:test_validation_loop_schema:^empty-schema.yaml.*top-level validation_loop.schema is empty or null"
    "forge-script-no-inherited-schema.yaml:test_validation_loop_schema:^forge-script-no-inherited-schema.yaml.*validation_loop has script but no schema.*no top-level schema"
    "overlay-script-no-inherited-schema.yaml:test_validation_loop_schema:^overlay-script-no-inherited-schema.yaml.*validation_loop has script but no schema.*no top-level schema"
    "missing-schema-file.yaml:test_schema_files_exist_and_valid:^missing-schema-file.yaml.*top-level schema file not found"
    "forge-missing-schema-file.yaml:test_schema_files_exist_and_valid:^forge-missing-schema-file.yaml.*forge.github.*schema file not found"
    "overlay-bad-json-schema.yaml:test_schema_files_exist_and_valid:^overlay-bad-json-schema.yaml.*overlays\[0\].*schema file is not valid JSON"
    "hardcoded-env-runner.yaml:test_no_hardcoded_schema:^hardcoded-env-runner.yaml: env.runner contains hardcoded FULLSEND_OUTPUT_SCHEMA"
    "hardcoded-forge-env-runner.yaml:test_no_hardcoded_schema:^hardcoded-forge-env-runner.yaml.*forge.*env.runner contains hardcoded"
    "hardcoded-forge-runner-env.yaml:test_no_hardcoded_schema:^hardcoded-forge-runner-env.yaml.*forge.*runner_env.*contains hardcoded"
    "hardcoded-overlay-env-runner.yaml:test_no_hardcoded_schema:^hardcoded-overlay-env-runner.yaml.*overlays\[0\].env.runner contains hardcoded"
    "hardcoded-runner-env.yaml:test_no_hardcoded_schema:^hardcoded-runner-env.yaml.*runner_env.*contains hardcoded FULLSEND_OUTPUT_SCHEMA"
    "hardcoded-overlay-runner-env.yaml:test_no_hardcoded_schema:^hardcoded-overlay-runner-env.yaml.*overlays\[0\].runner_env.*contains hardcoded"
    "bad-json-schema.yaml:test_schema_files_exist_and_valid:^bad-json-schema.yaml.*schema file is not valid JSON"
    "invalid-yaml.yaml:test_harness_yaml_valid:invalid YAML syntax"
  )

  for fixture_spec in "${expected_failures[@]}"; do
    local fixture_name="${fixture_spec%%:*}"
    local rest="${fixture_spec#*:}"
    local test_func="${rest%%:*}"
    local expected_message="${rest#*:}"
    local fixture_file="${fixtures_dir}/${fixture_name}"

    if [[ ! -f "${fixture_file}" ]]; then
      echo "Missing fixture: ${fixture_name}"
      found_error=1
      continue
    fi

    local output
    local exit_code=0
    # Run each test with HARNESS_DIR set to fixtures, and export REPO_ROOT so schema paths resolve correctly
    output="$(HARNESS_DIR="${fixtures_dir}" REPO_ROOT="${SCRIPT_DIR}"/test-fixtures ${test_func} 2>&1)" || exit_code=$?

    if [[ ${exit_code} -ne 0 ]] && echo "${output}" | grep -qE "${expected_message}"; then
      continue
    else
      echo "Fixture ${fixture_name}: exit_code=${exit_code}, expected nonzero with message matching '${expected_message}'"
      found_error=1
    fi
  done

  if [[ ${found_error} -eq 0 ]]; then
    return 0
  else
    return 1
  fi
}

# Test 6: Verify positive fixtures pass (prove the checks allow valid configs)
test_positive_fixtures() {
  local found_error=0
  local fixtures_dir="${SCRIPT_DIR}/test-fixtures/harness-config-good"

  if [[ ! -d "${fixtures_dir}" ]]; then
    return 0
  fi

  local expected_passes=(
    "null-schema-inheritance.yaml"
  )

  for fixture_name in "${expected_passes[@]}"; do
    local fixture_file="${fixtures_dir}/${fixture_name}"

    if [[ ! -f "${fixture_file}" ]]; then
      echo "Missing positive fixture: ${fixture_name}"
      found_error=1
      continue
    fi

    local output
    local exit_code=0
    output="$(HARNESS_DIR="${fixtures_dir}" REPO_ROOT="${SCRIPT_DIR}"/test-fixtures test_validation_loop_schema test_schema_files_exist_and_valid 2>&1)" || exit_code=$?

    if [[ ${exit_code} -eq 0 ]]; then
      continue
    else
      echo "Fixture ${fixture_name}: exit_code=${exit_code}, expected 0 (pass)"
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
run_test "negative-fixtures-fail" test_negative_fixtures
run_test "positive-fixtures-pass" test_positive_fixtures

if [[ ${FAILURES} -eq 0 ]]; then
  echo
  echo "✓ All harness config invariants pass"
  exit 0
else
  echo
  echo "✗ ${FAILURES} test(s) failed"
  exit 1
fi
