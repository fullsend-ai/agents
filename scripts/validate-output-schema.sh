#!/usr/bin/env bash
# validate-output-schema.sh — Validate agent output against a JSON Schema.
#
# Generic script used by the harness validation_loop (ADR 0022).
# Works for any agent — the schema path is configured in the harness.
#
# Required env vars:
#   FULLSEND_OUTPUT_SCHEMA — path to the JSON Schema file
#
# The script looks for triage-result.json (or any .json file) in the
# iteration output directory. The working directory is the iteration dir
# (set by run.go).

set -euo pipefail

: "${FULLSEND_OUTPUT_SCHEMA:?FULLSEND_OUTPUT_SCHEMA must be set}"

# Find the output JSON file in this iteration's output directory.
OUTPUT_DIR="output"
if [[ ! -d "${OUTPUT_DIR}" ]]; then
  echo "FAIL: output directory not found"
  exit 1
fi

# Prefer triage-result.json by name; fall back to any .json file.
if [[ -f "${OUTPUT_DIR}/triage-result.json" ]]; then
  RESULT_FILE="${OUTPUT_DIR}/triage-result.json"
else
  JSON_FILES=()
  while IFS= read -r -d '' f; do
    JSON_FILES+=("$f")
  done < <(find "${OUTPUT_DIR}" -maxdepth 1 -name '*.json' -print0)

  if [[ ${#JSON_FILES[@]} -eq 0 ]]; then
    echo "FAIL: no JSON files found in ${OUTPUT_DIR}/"
    exit 1
  fi

  if [[ ${#JSON_FILES[@]} -gt 1 ]]; then
    echo "WARN: multiple JSON files found, using ${JSON_FILES[0]}"
  fi

  RESULT_FILE="${JSON_FILES[0]}"
fi
echo "Validating: ${RESULT_FILE} against ${FULLSEND_OUTPUT_SCHEMA}"

# Validate JSON is parseable.
if ! python3 -m json.tool "${RESULT_FILE}" > /dev/null 2>&1; then
  echo "FAIL: ${RESULT_FILE} is not valid JSON"
  exit 1
fi

# Validate against schema using Python's jsonschema.
# jsonschema is required — fail hard if not installed.
if ! python3 -c "import jsonschema" 2>/dev/null; then
  echo "FAIL: python3 jsonschema package is not installed (required by ADR 0022)"
  exit 1
fi

if ! python3 -c "
import json, sys
from jsonschema import validate, ValidationError

with open(sys.argv[1]) as f:
    instance = json.load(f)
with open(sys.argv[2]) as f:
    schema = json.load(f)
try:
    validate(instance=instance, schema=schema)
    print('PASS: output validated against schema')
except ValidationError as e:
    print(f'FAIL: schema validation error: {e.message}')
    if e.path:
        print(f'  at: {\".\".join(str(p) for p in e.path)}')
    sys.exit(1)
" "${RESULT_FILE}" "${FULLSEND_OUTPUT_SCHEMA}"; then
  exit 1
fi
