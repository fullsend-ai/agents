#!/usr/bin/env bash
# relabel-retrigger-test.sh — Tests for scripts/lib/relabel-retrigger.lib.sh
#
# Run from the repo root:
#   bash scripts/relabel-retrigger-test.sh

set -euo pipefail

if [[ "${SCRIPT_TEST_TARGET:-source}" == "bundled" ]]; then
  echo "SKIP: relabel-retrigger-test (lib tests skipped in bundled mode)"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source post-failure-report.lib.sh first so gha_echo is real, matching how
# post-fix.src.sh actually composes these libraries at runtime — not a
# reimplementation of sanitization, the genuine shared function.
# shellcheck source=lib/post-failure-report.lib.sh
source "${SCRIPT_DIR}/lib/post-failure-report.lib.sh"
# shellcheck source=lib/relabel-retrigger.lib.sh
source "${SCRIPT_DIR}/lib/relabel-retrigger.lib.sh"

FAILURES=0

run_retrigger_test() {
  local test_name="$1" fail_call="$2" label_present_before="${3:-no}" \
        expect_remove_escalation="${4:-no}" expect_notice="${5:-no}" expect_add_warning="${6:-no}" \
        pr_view_fails="${7:-no}"

  # Stub gh: fail whichever call fail_call names, succeed otherwise, and
  # report label_present_before for the pre-check `pr view` call — unless
  # pr_view_fails is set, in which case `pr view` itself errors (rate
  # limit, transient auth failure) regardless of label_present_before, to
  # exercise the `|| labels_before=""` fallback that determines
  # label_was_present in that case. Records the exact invocation sequence
  # (including GH_TOKEN as seen at call time) so a bug in argument
  # order/values, or a wrong/missing token, fails this test — not just a
  # bug that happens to preserve line position, which is exactly what
  # broke the original (non-library) version of this fix.
  local gh_call_log
  gh_call_log="$(mktemp)"
  # shellcheck disable=SC2317  # called indirectly via retrigger_via_label, in a different sourced file
  gh() {
    echo "${GH_TOKEN:-<unset>} $*" >> "${gh_call_log}"
    if [[ "$*" == *"pr view"* ]]; then
      if [ "${pr_view_fails}" = "yes" ]; then
        echo "HTTP 429: rate limited" >&2
        return 1
      fi
      [ "${label_present_before}" = "yes" ] && echo "ready-for-review"
      return 0
    elif [[ "$*" == *"--remove-label"* ]]; then
      if [[ "${fail_call}" == "remove" || "${fail_call}" == "both" ]]; then
        printf '%s\r\n' 'HTTP 500%0A::error::spoofed%0D' >&2
        return 1
      fi
      return 0
    elif [[ "$*" == *"--add-label"* ]]; then
      if [[ "${fail_call}" == "add" || "${fail_call}" == "both" ]]; then
        printf '%s\r\n' 'HTTP 403%0A::error::spoofed-add%0D' >&2
        return 1
      fi
      return 0
    fi
    return 0
  }

  local output rc
  output="$(retrigger_via_label "org/repo" "123" "ready-for-review" "sentinel-token-xyz")"
  rc=$?
  unset -f gh

  if [ "${rc}" -ne 0 ]; then
    echo "FAIL: ${test_name} (exited ${rc} — retrigger_via_label must never hard-fail)"
    FAILURES=$((FAILURES + 1))
    rm -f "${gh_call_log}"
    return
  fi

  local expected_calls actual_calls
  expected_calls=$'sentinel-token-xyz pr view 123 --repo org/repo --json labels --jq .labels[].name\nsentinel-token-xyz pr edit 123 --repo org/repo --remove-label ready-for-review\nsentinel-token-xyz pr edit 123 --repo org/repo --add-label ready-for-review'
  actual_calls="$(cat "${gh_call_log}")"
  rm -f "${gh_call_log}"
  if [ "${actual_calls}" != "${expected_calls}" ]; then
    echo "FAIL: ${test_name} (unexpected gh invocation, or wrong/missing GH_TOKEN)"
    echo "  expected: ${expected_calls}"
    echo "  actual:   ${actual_calls}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # Three distinguishable messages: a remove-escalation warning (the
  # HIGH-finding fix — a genuine remove failure while the label was
  # actually present, which the idempotent add would otherwise swallow
  # silently), a benign notice (label simply wasn't there), and an
  # add-failure warning (unaffected by the precheck).
  local has_remove_escalation="no"
  echo "${output}" | grep -q "::warning::Failed to remove ready-for-review label.*even though it was present" && has_remove_escalation="yes"
  if [ "${has_remove_escalation}" != "${expect_remove_escalation}" ]; then
    echo "FAIL: ${test_name} (expected remove-escalation warning: '${expect_remove_escalation}', got: '${has_remove_escalation}')"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local has_notice="no"
  echo "${output}" | grep -q "::notice::Could not remove ready-for-review label" && has_notice="yes"
  if [ "${has_notice}" != "${expect_notice}" ]; then
    echo "FAIL: ${test_name} (expected benign notice: '${expect_notice}', got: '${has_notice}')"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local has_add_warning="no"
  echo "${output}" | grep -q "::warning::Failed to re-apply" && has_add_warning="yes"
  if [ "${has_add_warning}" != "${expect_add_warning}" ]; then
    echo "FAIL: ${test_name} (expected add-failure warning: '${expect_add_warning}', got: '${has_add_warning}')"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # When any of the three fires, the injected poison stderr ("HTTP
  # 500%0A::error::spoofed%0D" for remove, "HTTP 403%0A::error::spoofed-add%0D"
  # for add) must be fully sanitized by gha_echo (:: and %0A/%0D) and by this
  # lib's own newline/CR flattening — no bare "::" beyond the recognized
  # ::notice::/::warning:: prefix, no percent-encoded escapes, and no
  # embedded line breaks splitting the message across raw output lines.
  # expected_fragment asserts the captured stderr detail actually made it
  # into the message — not just that no bad characters are present, which
  # would trivially pass even if the detail were discarded entirely (e.g. a
  # regression back to 2>/dev/null on the add-label call).
  assert_sanitized_line() {
    local grep_pattern="$1" prefix="$2" expected_fragment="$3"
    local line body
    line="$(echo "${output}" | grep "${grep_pattern}")"
    body="${line#*"${prefix}"}"
    if [[ "${body}" == *"::"* ]] || [[ "${body}" == *"%0A"* ]] \
       || [[ "${body}" == *"%0a"* ]] || [[ "${body}" == *"%0D"* ]] \
       || [[ "${body}" == *"%0d"* ]]; then
      echo "FAIL: ${test_name} (unsanitized :: or percent-encoded newline/CR leaked into ${prefix} line)"
      echo "  line: ${body}"
      FAILURES=$((FAILURES + 1))
      return 1
    fi
    if [[ "${body}" != *"${expected_fragment}"* ]]; then
      echo "FAIL: ${test_name} (captured stderr detail missing from ${prefix} line — expected to find '${expected_fragment}')"
      echo "  line: ${body}"
      FAILURES=$((FAILURES + 1))
      return 1
    fi
    return 0
  }

  if [ "${has_remove_escalation}" = "yes" ]; then
    assert_sanitized_line "::warning::Failed to remove ready-for-review label" "::warning::" "500" || return
  fi
  if [ "${has_notice}" = "yes" ]; then
    assert_sanitized_line "::notice::Could not remove" "::notice::" "500" || return
  fi
  if [ "${has_add_warning}" = "yes" ]; then
    assert_sanitized_line "::warning::Failed to re-apply" "::warning::" "403" || return
  fi

  if [ "${has_remove_escalation}" = "yes" ] || [ "${has_notice}" = "yes" ] || [ "${has_add_warning}" = "yes" ]; then
    local expected_lines=0
    [ "${has_remove_escalation}" = "yes" ] && expected_lines=$((expected_lines + 1))
    [ "${has_notice}" = "yes" ] && expected_lines=$((expected_lines + 1))
    [ "${has_add_warning}" = "yes" ] && expected_lines=$((expected_lines + 1))
    local actual_lines
    actual_lines="$(echo "${output}" | wc -l)"
    if [ "${actual_lines}" -ne "${expected_lines}" ]; then
      echo "FAIL: ${test_name} (embedded newline/CR leaked an extra output line — expected ${expected_lines}, got ${actual_lines})"
      echo "  output: ${output}"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

# Both calls succeed, label wasn't present beforehand (irrelevant since
# remove succeeds either way) → no notice, no warning.
run_retrigger_test "retrigger-both-succeed" "none" "no" "no" "no" "no"

# Remove fails, and the label genuinely wasn't present beforehand — benign,
# non-fatal notice, add still runs and succeeds, no escalation.
run_retrigger_test "retrigger-remove-fails-label-was-absent" "remove" "no" "no" "yes" "no"

# Remove fails, but the label WAS present beforehand — the HIGH-finding fix:
# a genuine failure that the idempotent add-label call would otherwise
# silently swallow (no absent-to-present transition, no fresh labeled
# event) must escalate to a warning, not the benign notice.
run_retrigger_test "retrigger-remove-fails-label-was-present" "remove" "yes" "yes" "no" "no"

# Add fails (API error, label deleted from repo) — warns, does not fail,
# regardless of whether the label was present before the remove attempt.
run_retrigger_test "retrigger-add-fails" "add" "no" "no" "no" "yes"

# Both fail, label was present beforehand — remove-escalation warning AND
# add-failure warning both fire, never a hard failure.
run_retrigger_test "retrigger-both-fail-label-was-present" "both" "yes" "yes" "no" "yes"

# The pr view precheck itself fails (rate limit, transient auth error) — the
# `|| labels_before=""` fallback must make label_was_present default safely
# to "false", so a subsequent --remove-label failure gets the benign notice
# rather than a false escalation to warning. label_present_before is "no"
# here but is moot: pr_view_fails means the mock never gets to honor it.
run_retrigger_test "retrigger-pr-view-fails-defaults-to-absent" "remove" "no" "no" "yes" "no" "yes"

# ---------------------------------------------------------------------------
# retrigger_via_label runs in the caller's shell (sourced, not a subshell)
# under post-fix.src.sh's `set -euo pipefail`. An earlier version used
# mktemp plus a `tr | tr` pipe to capture and flatten stderr — an mktemp
# failure, or a pipefail-tripped pipe, would abort the whole calling script
# despite this function's contract to never fail the caller. The library was
# rewritten to use pure bash builtins (command substitution, parameter
# expansion) specifically to eliminate that mktemp dependency entirely — this
# test proves mktemp is never invoked at all, not merely that a broken
# mktemp is tolerated. (A shadowed `mktemp() { return 1; }` alone would prove
# nothing here since retrigger_via_label doesn't call mktemp — the assertion
# that matters is that it's never called, which requires recording calls via
# a file, since retrigger_via_label runs inside the $(...) subshell below and
# can't mutate this function's local variables directly.)
# ---------------------------------------------------------------------------
run_retrigger_does_not_depend_on_mktemp_test() {
  local test_name="retrigger-does-not-depend-on-mktemp"

  # Use the real mktemp to create the call-log file before shadowing it.
  local mktemp_call_log
  mktemp_call_log="$(command mktemp)"

  # shellcheck disable=SC2317  # called indirectly via retrigger_via_label, in a different sourced file
  gh() {
    [[ "$*" == *"--remove-label"* ]] && return 1
    return 0
  }
  # shellcheck disable=SC2317  # shadowed to record any call and fail loudly if invoked
  mktemp() { echo "called" >> "${mktemp_call_log}"; return 1; }

  # Capture stderr too (2>&1) — an mktemp-dependent version of this function
  # doesn't necessarily abort outright (bash's set -e/command-substitution
  # interaction is more forgiving than it looks); the earlier, buggy version
  # instead silently tried to redirect to an empty filename and leaked a raw
  # "No such file or directory" shell error, which is just as unacceptable
  # for a function documented as never failing its caller.
  local combined rc
  combined="$(retrigger_via_label "org/repo" "123" "ready-for-review" "sentinel-token-xyz" 2>&1)"
  rc=$?
  unset -f gh
  unset -f mktemp

  if [ "${rc}" -ne 0 ]; then
    echo "FAIL: ${test_name} (exited ${rc} with mktemp broken — retrigger_via_label must not depend on mktemp)"
    FAILURES=$((FAILURES + 1))
    rm -f "${mktemp_call_log}"
    return
  fi

  if [ -s "${mktemp_call_log}" ]; then
    echo "FAIL: ${test_name} (retrigger_via_label called mktemp — it must use pure bash builtins only, see the library's own comment on why)"
    echo "  calls: $(cat "${mktemp_call_log}")"
    FAILURES=$((FAILURES + 1))
    rm -f "${mktemp_call_log}"
    return
  fi
  rm -f "${mktemp_call_log}"

  if [[ "${combined}" == *"No such file or directory"* ]] || [[ "${combined}" == *"mktemp"* ]]; then
    echo "FAIL: ${test_name} (leaked a raw shell/mktemp error — retrigger_via_label must not depend on mktemp at all)"
    echo "  output: ${combined}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_retrigger_does_not_depend_on_mktemp_test

# ---------------------------------------------------------------------------
# retrigger_via_label's notice/warning fallback (used when gha_echo isn't
# available — not the case in post-fix.src.sh today, but this library is
# meant to be sourced by other agent post-scripts too) must sanitize the
# same :: / %0A / %0D vectors gha_echo itself strips. Temporarily unsets
# gha_echo to exercise that fallback path directly, then restores it by
# re-sourcing post-failure-report.lib.sh so later runs of this suite (or a
# future test appended after this one) still see the real function.
# ---------------------------------------------------------------------------
run_retrigger_fallback_sanitization_test() {
  local test_name="relabel-fallback-sanitizes-without-gha-echo"

  unset -f gha_echo

  # shellcheck disable=SC2317  # called indirectly via retrigger_via_label, in a different sourced file
  gh() {
    if [[ "$*" == *"--remove-label"* ]]; then
      printf '%s' 'HTTP 500%0A::error::spoofed%0D' >&2
      return 1
    fi
    return 0
  }

  local output rc
  output="$(retrigger_via_label "org/repo" "123" "ready-for-review" "sentinel-token-xyz" 2>&1)"
  rc=$?
  unset -f gh
  # post-failure-report.lib.sh has an include guard (POST_FAILURE_REPORT_SH_LOADED)
  # that makes a plain re-source a no-op — unset it first so this actually
  # redefines gha_echo, not just appears to.
  unset POST_FAILURE_REPORT_SH_LOADED
  # shellcheck source=lib/post-failure-report.lib.sh
  source "${SCRIPT_DIR}/lib/post-failure-report.lib.sh"

  if [ "${rc}" -ne 0 ]; then
    echo "FAIL: ${test_name} (exited ${rc} without gha_echo — retrigger_via_label must never hard-fail)"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ "${output}" == *"::"* ]] || [[ "${output}" == *"%0A"* ]] \
     || [[ "${output}" == *"%0a"* ]] || [[ "${output}" == *"%0D"* ]] \
     || [[ "${output}" == *"%0d"* ]]; then
    echo "FAIL: ${test_name} (unsanitized :: or percent-encoded newline/CR leaked via the no-gha_echo fallback)"
    echo "  output: ${output}"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! declare -F gha_echo >/dev/null 2>&1; then
    echo "FAIL: ${test_name} (gha_echo was not actually restored after the fallback test — a test appended after this one would silently exercise the fallback path instead of the real gha_echo)"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_retrigger_fallback_sanitization_test

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
