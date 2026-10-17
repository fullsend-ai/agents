#!/usr/bin/env bash
# Tests for eval/lint-release-cases.py; requires Python 3 and PyYAML.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINTER="${SCRIPT_DIR}/lint-release-cases.py"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
FAILURES=0

run_case() {
  local name="$1" expected_exit="$2" expected_output="$3"
  local output actual_exit=0
  output="$(REPO_ROOT="${WORKDIR}/${name}" python3 "${LINTER}" 2>&1)" || actual_exit=$?
  if [[ "$actual_exit" != "$expected_exit" || "$output" != *"$expected_output"* ]]; then
    echo "FAIL: ${name} (exit ${actual_exit}, expected ${expected_exit}; expected '${expected_output}')"
    echo "$output"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${name}"
  fi
}

# A fixture needs only the paths consumed by the linter; no live eval runs.
make_agent() {
  mkdir -p "${WORKDIR}/$1/eval/$2/cases/smoke"
  printf 'agent: %s\n' "$2" > "${WORKDIR}/$1/eval/$2/eval.yaml"
}

for value in true True TRUE tagged-true tagged-True tagged-TRUE false missing quoted number yes on nested malformed null comment-only; do
  make_agent "$value" code
  annotations="${WORKDIR}/${value}/eval/code/cases/smoke/annotations.yaml"
  case "$value" in
    true) printf 'release: true # smoke case\n' > "$annotations" ;;
    True|TRUE) printf 'release: %s\n' "$value" > "$annotations" ;;
    tagged-*) printf 'release: !!bool %s\n' "${value#tagged-}" > "$annotations" ;;
    false) printf 'release: false\n' > "$annotations" ;;
    missing) printf 'max_cost_usd: 1\n' > "$annotations" ;;
    quoted) printf 'release: "true"\n' > "$annotations" ;;
    number) printf 'release: 1\n' > "$annotations" ;;
    yes) printf 'release: yes\n' > "$annotations" ;;
    on) printf 'release: on\n' > "$annotations" ;;
    nested) printf 'metadata:\n  release: true\n' > "$annotations" ;;
    malformed) printf 'release: [\n' > "$annotations" ;;
    null) printf 'release: null\n' > "$annotations" ;;
    comment-only) printf '# No release marker\n' > "$annotations" ;;
  esac
  if [[ "$value" == true || "$value" == tagged-true ]]; then
    run_case "$value" 0 'code: OK (1 release-tier case(s))'
  else
    run_case "$value" 1 'eval/code/eval.yaml: no release-tier case'
  fi
done

mkdir -p "${WORKDIR}/no-manifests/eval"
run_case no-manifests 1 'ERROR: no eval/*/eval.yaml manifests found'

make_agent invalid-utf8 code
make_agent invalid-utf8 review
printf '\377\n' > "${WORKDIR}/invalid-utf8/eval/code/cases/smoke/annotations.yaml"
run_case invalid-utf8 1 'ERROR: eval/code/cases/smoke/annotations.yaml:'
run_case invalid-utf8 1 'eval/review/eval.yaml: no release-tier case'
printf 'release: true\n' > "${WORKDIR}/invalid-utf8/eval/review/cases/smoke/annotations.yaml"
run_case invalid-utf8 1 'review: OK (1 release-tier case(s))'

# Hidden case directories are not selected by the release runner's shell glob.
make_agent hidden-case code
mkdir -p "${WORKDIR}/hidden-case/eval/code/cases/.smoke"
printf 'release: true\n' > "${WORKDIR}/hidden-case/eval/code/cases/.smoke/annotations.yaml"
run_case hidden-case 1 'eval/code/eval.yaml: no release-tier case'
printf 'release: true\n' > "${WORKDIR}/hidden-case/eval/code/cases/smoke/annotations.yaml"
run_case hidden-case 0 'code: OK (1 release-tier case(s))'

make_agent no-annotations code
run_case no-annotations 1 'eval/code/eval.yaml: no release-tier case'

make_agent no-cases code
rm -rf "${WORKDIR}/no-cases/eval/code/cases"
run_case no-cases 1 'eval/code/eval.yaml: no release-tier case'

make_agent multiple-agents code
make_agent multiple-agents review
printf 'release: true\n' > "${WORKDIR}/multiple-agents/eval/code/cases/smoke/annotations.yaml"
run_case multiple-agents 1 'eval/review/eval.yaml: no release-tier case'
printf 'release: true\n' > "${WORKDIR}/multiple-agents/eval/review/cases/smoke/annotations.yaml"
run_case multiple-agents 0 'review: OK'

make_agent multiple-cases code
mkdir -p "${WORKDIR}/multiple-cases/eval/code/cases/full"
printf 'release: true\n' > "${WORKDIR}/multiple-cases/eval/code/cases/smoke/annotations.yaml"
printf 'release: false\n' > "${WORKDIR}/multiple-cases/eval/code/cases/full/annotations.yaml"
run_case multiple-cases 0 'code: OK (1 release-tier case(s))'
printf 'release: true\n' > "${WORKDIR}/multiple-cases/eval/code/cases/full/annotations.yaml"
run_case multiple-cases 0 'code: OK (2 release-tier case(s))'
printf 'release: false\n' > "${WORKDIR}/multiple-cases/eval/code/cases/full/annotations.yaml"
# Removing the last release marker must fail even if other cases remain.
rm "${WORKDIR}/multiple-cases/eval/code/cases/smoke/annotations.yaml"
run_case multiple-cases 1 'eval/code/eval.yaml: no release-tier case'

make_agent non-agent-directory code
printf 'release: true\n' > "${WORKDIR}/non-agent-directory/eval/code/cases/smoke/annotations.yaml"
mkdir -p "${WORKDIR}/non-agent-directory/eval/measurements"
run_case non-agent-directory 0 'code: OK'

echo ""
if [[ "$FAILURES" -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
