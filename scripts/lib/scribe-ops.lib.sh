#!/usr/bin/env bash
# shellcheck shell=bash
# scribe-ops.lib.sh — Forge-dispatch wrapper for scribe operations.
#
# Sources the correct forge-specific ops based on FULLSEND_FORGE. When
# FULLSEND_TRACKER=jira, additionally sources the Jira tracker ops, which
# redefine the backlog, closed-issue, and issue-creation functions so they
# target Jira while repo context (open PRs, docs) stays on the forge.
# FULLSEND_TRACKER defaults to FULLSEND_FORGE.
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${SCRIBE_OPS_SH_LOADED:-}" ]] && return 0
SCRIBE_OPS_SH_LOADED=1

_gha_sanitize() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'; }

# Strip the characters that let untrusted text (e.g. Drive document titles,
# issue #706) break out of a single display line, hide/reorder content, or be
# removed later and reassemble a secret past a sensitive-content check:
# - CSI ANSI escape sequences;
# - every C0 control char and DEL (\000-\037\177), which covers CR, LF, VT, FF,
#   TAB and a bare ESC — so a title cannot inject extra log/report lines;
# - backticks (\140), which the step-summary code span removes anyway — stripping
#   them here means the redactor sees the same text that is published, so a title
#   like `123-45-<bt>6789<bt>` cannot evade the SSN check and then reassemble;
# - Unicode line/paragraph separators (U+2028/U+2029), bidi overrides and
#   isolates (U+202A-202E, U+2066-2069), zero-width chars, BOM, and tag chars.
# Shared by the Slack, step-summary and pre-scribe log paths so all are equally
# strong, and run before redaction so the redactor matches what is published.
# perl is already a runner dependency (see pre-scribe.sh).
strip_unsafe_chars() {
  printf '%s' "$1" \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
    | tr -d '\000-\037\177\140' \
    | perl -CS -pe 's/[\x{2028}\x{2029}\x{200B}\x{200C}\x{200D}\x{FEFF}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{E0000}-\x{E007F}]//g'
}

# Redact sensitive spans in a meeting title / Drive document name (issue #706).
# Titles are raw, never-scrubbed Drive names shown verbatim in Slack, the step
# summary and the pre-scribe job log, so they can carry secrets AND the PII that
# pre-scribe scrubs from note bodies (phone / IPv4 / card). Unlike the boolean
# `contains_sensitive` gate used for topics/new-issues (deliberately left
# unchanged), this replaces only the MATCHING substring with [redacted] so the
# rest of the meeting name stays identifiable, and Luhn-validates card-like digit
# runs so version numbers and meeting IDs (e.g. "OKR 1234567890123") are not
# blanked. The secret patterns mirror `contains_sensitive` in post-scribe.sh and
# must be kept in sync with it. Input must already be strip_unsafe_chars'd (no
# control chars) so it is safe to hand to perl as data.
redact_sensitive_title() {
  printf '%s' "$1" | perl -CS -pe '
    sub luhn {
      my $d = shift; $d =~ s/\D//g;
      return 0 if length($d) < 13 || length($d) > 19;
      my ($sum, $alt) = (0, 0);
      for my $i (reverse 0 .. length($d) - 1) {
        my $n = substr($d, $i, 1);
        if ($alt) { $n *= 2; $n -= 9 if $n > 9; }
        $sum += $n; $alt = !$alt;
      }
      return $sum % 10 == 0;
    }
    my $R = "[redacted]";
    # Secrets / credentials (mirror contains_sensitive in post-scribe.sh).
    s/(?:ghp|gho|ghs|ghr)_[A-Za-z0-9_]{36,}/$R/gi;
    s/\b(?:AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}\b/$R/g;
    s/-----BEGIN[^\n]*PRIVATE KEY[^\n]*/$R/g;
    s/https:\/\/hooks\.slack\.com\/services\/T[A-Z0-9]+\/B[A-Z0-9]+\/[A-Za-z0-9]+/$R/g;
    s/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/$R/g;
    s/(?i:(?:api[_-]?key|token|secret|password|bearer)\s*[:=]\s*[\x27\x22]?[A-Za-z0-9_.~+\/-]{20,})/$R/g;
    # PII pre-scribe scrubs from note bodies, applied per-span to titles.
    s/\b[A-Za-z0-9._%+-]+\@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/$R/g;
    s/\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b/$R/g;
    s/\b(?:\+?1[-. ]?)?\(?[0-9]{3}\)?[-. ]?[0-9]{3}[-. ]?[0-9]{4}\b/$R/g;
    s/\+[0-9]{1,3}[-. ]?[0-9]{4,14}\b/$R/g;
    s/\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b/$R/g;
    # Card-like run (13-19 digits, optional single space/dash between digits):
    # only redact when it passes Luhn, so numeric IDs/versions survive.
    s/(?<![0-9])([0-9](?:[ -]?[0-9]){12,18})(?![0-9])/ luhn($1) ? $R : $1 /ge;
  '
}

case "${FULLSEND_FORGE:-}" in
  github)
    source "${SCRIPT_DIR}/lib/github-scribe-ops.lib.sh"
    ;;
  gitlab)
    source "${SCRIPT_DIR}/lib/gitlab-scribe-ops.lib.sh"
    ;;
  *)
    echo "ERROR: invalid FULLSEND_FORGE: '$(_gha_sanitize "${FULLSEND_FORGE:-}")' — pass --forge <github|gitlab> or set FULLSEND_FORGE" >&2
    exit 1
    ;;
esac

FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE}}"

case "${FULLSEND_TRACKER}" in
  "${FULLSEND_FORGE}") ;;
  jira)
    source "${SCRIPT_DIR}/lib/jira-scribe-ops.lib.sh"
    ;;
  *)
    echo "ERROR: invalid FULLSEND_TRACKER: '$(_gha_sanitize "${FULLSEND_TRACKER}")' — must be 'jira' or match FULLSEND_FORGE" >&2
    exit 1
    ;;
esac
