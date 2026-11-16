#!/usr/bin/env bash
# GENERATED from post-scribe.src.sh — DO NOT EDIT. Run: make script-build
# post-scribe.sh — Parse scribe agent JSON output, apply security gate,
# and write to the repository (comments on existing issues, new issues).
#
# Runs on the host after sandbox cleanup.
#
# Required env vars:
#   SCRIBE_REPO    — target repository (owner/name or group/project)
#   FULLSEND_FORGE — "github" or "gitlab"
#   SCRIBE_DRY_RUN — "true" to preview without writing (ALWAYS true during dev)
#
# Forge-specific token env vars:
#   GH_TOKEN       — GitHub token (when FULLSEND_FORGE=github)
#   GITLAB_TOKEN   — GitLab token (when FULLSEND_FORGE=gitlab)
#
# Jira issue creation (FULLSEND_TRACKER=jira): new issues are created in
# SCRIBE_JIRA_PROJECT; comments are not supported. See
# lib/jira-scribe-ops.lib.sh for the JIRA_* variables and FULLSEND_DIR.
# JIRA_USER_EMAIL is optional: unset or empty selects Bearer auth.
# FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET can replace
# JIRA_TOKEN; they need JIRA_API_URL.
#
# Optional env vars:
#   SCRIBE_MODE              — "all" (default), "comments_only", "new_issues_only"
#   SCRIBE_SLACK_WEBHOOK_URL — Slack incoming webhook for notification (skip if unset)
#
# SAFETY: This script REFUSES to run if SCRIBE_DRY_RUN is not explicitly set.
# This prevents accidental writes during development.

set -euo pipefail

: "${FULLSEND_FORGE:?FULLSEND_FORGE must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/scribe-ops.lib.sh
# BEGIN bundled: lib/scribe-ops.lib.sh
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
# - Unicode line/paragraph separators (U+2028/U+2029);
# - every Unicode "Default_Ignorable_Code_Point" (DI) character: this is the
#   Unicode property specifically defined for characters "recommended to be
#   ignored during rendering" — it covers soft hyphen, word joiner, LRM/RLM/
#   ALM, bidi embeds/overrides/isolates, zero-width chars, BOM, Mongolian
#   vowel separator, tag characters, AND variation selectors (U+FE00-FE0F,
#   U+E0100-E01EF, category Mn — not Cf/Cc, so earlier revisions that matched
#   by general-category class alone missed them). A single invisible
#   character of ANY of these kinds could split a secret/PII pattern so
#   neither half matched, passing the gate below while rendering
#   invisibly — exposing the full, unredacted value. Matching the DI property
#   instead of a general-category class or an enumerated list closes that
#   gap for the whole class of invisible-by-design code points at once,
#   rather than one newly-discovered exception at a time;
# - every Unicode "Control" (Cc) character, which additionally covers the C1
#   range (U+0080-009F) that the C0/DEL `tr` above does not reach — not
#   itself part of DI.
# Shared by the Slack, step-summary and pre-scribe log paths so all are equally
# strong, and run before redaction so the redactor matches what is published.
# perl is already a runner dependency (see pre-scribe.sh).
strip_unsafe_chars() {
  printf '%s' "$1" \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
    | tr -d '\000-\037\177\140' \
    | perl -CS -pe 's/[\p{Default_Ignorable_Code_Point}\p{Cc}\x{2028}\x{2029}]//g'
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
    # Find and redact card-shaped spans in $s, returning the modified string.
    # A single `s///g` cannot do this: once a greedy candidate (e.g. an
    # unrelated 4-digit number immediately before a real PAN) is tried and
    # fails Luhn, `/g` resumes scanning AFTER it and never retries starting
    # one token later, so the real PAN underneath is never checked. Instead,
    # tokenize into digit-runs ("tokens") and the single-space/dash gaps that
    # chain them into a "run", then within each run try candidate WINDOWS of
    # consecutive tokens (longest-first at each start) against known PAN
    # shapes — contiguous 13-19 digits, 4-digit groups with a 1-7 digit final
    # group (the common grouping), or Amex'"'"'s 4-6-5 grouping — Luhn-checking
    # only shape-valid windows. On the first Luhn-valid window, commit it and
    # resume scanning right after; otherwise advance the start by one token so
    # an overlapping later window still gets tried. Restricting candidates to
    # whole-token windows of a recognized shape (rather than arbitrary digit
    # sub-strings) keeps the false-positive rate low: a short numeric ID
    # (Sprint/OKR) never has the right token shape to be tried at all, so it
    # never reaches Luhn.
    sub redact_cards {
      my ($s) = @_;
      my @tokens;
      while ($s =~ /([0-9]+)/g) {
        push @tokens, { text => $1, start => $-[1], end => $+[1] };
      }
      return $s unless @tokens;
      my @runs;
      my @cur = (0);
      for my $i (1 .. $#tokens) {
        my $gap = substr($s, $tokens[$i - 1]{end}, $tokens[$i]{start} - $tokens[$i - 1]{end});
        if ($gap eq " " || $gap eq "-") { push @cur, $i; }
        else { push @runs, [@cur]; @cur = ($i); }
      }
      push @runs, [@cur];
      my @replacements;
      for my $run (@runs) {
        my @idx = @$run;
        my $n = scalar @idx;
        my $start = 0;
        while ($start < $n) {
          my $committed = 0;
          # A valid PAN has at most 19 digits and every token has at least one,
          # so a window can never need more than 19 tokens. Capping $end here
          # bounds the inner loop (and the O(count) window/width rebuild inside
          # it) to a constant, making the scan linear in the number of tokens
          # instead of cubic — important because titles are untrusted (issue
          # #706) and a long digit-heavy title is otherwise an algorithmic DoS.
          my $max_end = $start + 18;
          $max_end = $n - 1 if $max_end > $n - 1;
          for (my $end = $max_end; $end >= $start; $end--) {
            my @window = @idx[$start .. $end];
            my $count = scalar @window;
            my @widths = map { length($tokens[$_]{text}) } @window;
            my $total = 0; $total += $_ for @widths;
            my $shape_ok = 0;
            if ($count == 1 && $widths[0] >= 13 && $widths[0] <= 19) {
              $shape_ok = 1; # standalone contiguous 13-19 digit run
            } elsif ($count >= 1) {
              my $last = $widths[-1];
              my $all4 = 1;
              for my $w (@widths[0 .. $count - 2]) { $all4 = 0 if $w != 4; }
              if ($all4 && $last >= 1 && $last <= 7 && $total >= 13 && $total <= 19) {
                $shape_ok = 1; # 4-4-...-(1-7) grouping
              }
            }
            if (!$shape_ok && $count == 3 && $widths[0] == 4 && $widths[1] == 6 && $widths[2] == 5) {
              $shape_ok = 1; # Amex 4-6-5 grouping
            }
            next unless $shape_ok;
            my $digits = join("", map { $tokens[$_]{text} } @window);
            if (luhn($digits)) {
              push @replacements, [$tokens[$idx[$start]]{start}, $tokens[$idx[$end]]{end}, "[redacted]"];
              $start = $end + 1;
              $committed = 1;
              last;
            }
          }
          $start++ unless $committed;
        }
      }
      return $s unless @replacements;
      my $out = ""; my $pos = 0;
      for my $r (@replacements) {
        my ($rs, $re, $txt) = @$r;
        $out .= substr($s, $pos, $rs - $pos);
        $out .= $txt;
        $pos = $re;
      }
      $out .= substr($s, $pos);
      return $out;
    }
    my $R = "[redacted]";
    # Secrets / credentials (mirror contains_sensitive in post-scribe.sh — its
    # ghp/AKIA/BEGIN alternation is grepped with -i, so match case-insensitively
    # here too). Also add the AWS-secret-access-key and private_key_id patterns
    # pre-scribe scrubs from note bodies (pre-scribe.src.sh): contains_sensitive
    # itself does not have them, but titles are raw/never-scrubbed like bodies,
    # so the same credential patterns apply. Keep all three lists in sync.
    s/(?:ghp|gho|ghs|ghr)_[A-Za-z0-9_]{36,}/$R/gi;
    s/\b(?:AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}\b/$R/gi;
    s/-----BEGIN[^\n]*PRIVATE KEY[^\n]*/$R/gi;
    s/aws.?secret.?(?:access)?.?key\s*[:=]\s*[A-Za-z0-9\/+=]{40}/$R/gi;
    s/(?i:private_key_id)\s*[:=]\s*[\x27\x22]?[a-f0-9]{40}[\x27\x22]?/$R/g;
    s/https:\/\/hooks\.slack\.com\/services\/T[A-Z0-9]+\/B[A-Z0-9]+\/[A-Za-z0-9]+/$R/g;
    s/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/$R/g;
    s/(?i:(?:api[_-]?key|token|secret|password|bearer)\s*[:=]\s*[\x27\x22]?[A-Za-z0-9_.~+\/-]{20,})/$R/g;
    # PII pre-scribe scrubs from note bodies, applied per-span to titles.
    s/\b[A-Za-z0-9._%+-]+\@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/$R/g;
    s/\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b/$R/g;
    s/\b(?:\+?1[-. ]?)?\(?[0-9]{3}\)?[-. ]?[0-9]{3}[-. ]?[0-9]{4}\b/$R/g;
    s/\+[0-9]{1,3}[-. ]?[0-9]{4,14}\b/$R/g;
    s/\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b/$R/g;
    $_ = redact_cards($_);
  '
}

# Redact PII patterns from Google Meet note bodies before the sandboxed agent
# sees them. Predates issue #706; moved here (from inline in pre-scribe.src.sh)
# so it is directly testable alongside redact_sensitive_title above — the two
# functions mirror each other's secret/PII patterns and must be kept in sync.
# Ordered: specific patterns first, generic last (matches Go sanitizer.go).
scrub_note_pii() {
  printf '%s\n' "$1" \
    | sed -E 's/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/[REDACTED]/g' \
    | sed -E 's/\b(\+?1[-. ]?)?\(?[0-9]{3}\)?[-. ]?[0-9]{3}[-. ]?[0-9]{4}\b/[REDACTED]/g' \
    | sed -E 's/\+[0-9]{1,3}[-. ]?[0-9]{4,14}\b/[REDACTED]/g' \
    | sed -E 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/[REDACTED]/g' \
    | sed -E 's/\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b/[REDACTED]/g' \
    | sed -E 's/\b([0-9][ -]?){13,19}\b/[REDACTED]/g' \
    | sed -E 's/\b(AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}\b/[REDACTED]/g' \
    | sed -E 's/[Aa][Ww][Ss].?[Ss][Ee][Cc][Rr][Ee][Tt].?([Aa][Cc][Cc][Ee][Ss][Ss])?.?[Kk][Ee][Yy][[:space:]]*[:=][[:space:]]*[A-Za-z0-9\/+=]{40}/[REDACTED]/g' \
    | sed -E 's/\b(ghp|gho|ghs|ghr)_[A-Za-z0-9_]{36,255}\b/[REDACTED]/g' \
    | sed -E 's|https://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+|[REDACTED]|g' \
    | sed -E 's/-----BEGIN[[:space:]]+(RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----.*/[REDACTED]/g' \
    | sed -E 's/[Pp][Rr][Ii][Vv][Aa][Tt][Ee]_[Kk][Ee][Yy]_[Ii][Dd][[:space:]]*[:=][[:space:]]*['"'"'"]?[a-f0-9]{40}['"'"'"]?/[REDACTED]/g' \
    | sed -E 's/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/[REDACTED]/g' \
    | sed -E 's/([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Bb][Ee][Aa][Rr][Ee][Rr])[[:space:]]*[:=][[:space:]]*['"'"'"]?[A-Za-z0-9_.~+\/-]{20,}['"'"'"]?/[REDACTED]/g'
}

case "${FULLSEND_FORGE:-}" in
  github)
# BEGIN bundled: lib/github-scribe-ops.lib.sh
# shellcheck shell=bash
# github-scribe-ops.lib.sh — GitHub forge operations for scribe scripts.
#
# Bundled into pre-scribe.sh and post-scribe.sh via scribe-ops.lib.sh.
# All functions use the gh CLI and the GitHub REST API.
#
# Expected env vars:
#   SCRIBE_REPO  — GitHub repository (owner/name)
#   GH_TOKEN     — GitHub token with issues read/write scope

[[ -n "${GITHUB_SCRIBE_OPS_SH_LOADED:-}" ]] && return 0
GITHUB_SCRIBE_OPS_SH_LOADED=1

# shellcheck source=github-host.lib.sh
# BEGIN bundled: lib/github-host.lib.sh
# shellcheck shell=bash
# github-host.lib.sh — Shared GitHub host handling for GitHub ops.
#
# Derives the GitHub origin the run executes against from GITHUB_SERVER_URL,
# a GitHub Actions default variable (https://github.com on github.com, the
# instance URL on GitHub Enterprise Server). Defaults to https://github.com
# when unset. Issue/PR URL validation, URL parsing and generated links use
# this origin instead of a hard-coded github.com.
#
# Sourced by the github-*-ops.lib.sh files and inlined by the bundler.

[[ -n "${GITHUB_HOST_SH_LOADED:-}" ]] && return 0
GITHUB_HOST_SH_LOADED=1

# Prints the GitHub origin (https://host[:port]) without a trailing slash.
# Fails closed when GITHUB_SERVER_URL is not an HTTPS origin.
_github_server_url() {
  local origin="${GITHUB_SERVER_URL:-https://github.com}"
  origin="${origin%/}"
  if [[ ! "${origin}" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]]; then
    echo "ERROR: GITHUB_SERVER_URL is not an HTTPS origin (https://host[:port]): $(printf '%s' "${origin}" | tr -d '\n\r')" >&2
    return 1
  fi
  printf '%s\n' "${origin}"
}

# Prints the remainder of a URL after "<origin>/" when the URL is on the
# GitHub origin; fails (printing nothing) when it is on another host.
_github_url_path() {
  local url="$1" base
  base="$(_github_server_url)/" || return 1
  [[ "${url}" == "${base}"* ]] || return 1
  printf '%s\n' "${url#"${base}"}"
}
# END bundled: lib/github-host.lib.sh

# --- Pre-script: repo context ---

# Fetch all open items from the issues endpoint (paginated). GitHub's REST
# /issues endpoint includes pull requests — callers filter them out.
forge_fetch_open_issues_raw() {
  local repo="$1" output_file="$2"
  gh api --paginate "repos/${repo}/issues?state=open&per_page=100" \
    > "${output_file}"
}

# Filter raw issues response into the backlog format: remove PRs, extract
# fields, truncate bodies to 500 chars.
forge_filter_issues_to_backlog() {
  local raw_file="$1" backlog_file="$2"
  jq -s '[.[][] | select(.pull_request == null) | {number, title, body, labels, milestone, url: .html_url}]' "${raw_file}" \
    | jq '[.[] | .body = ((.body // "")[:500] + if ((.body // "") | length) > 500 then "…" else "" end)]' \
    > "${backlog_file}"
}

# Count total paginated items (issues + PRs on GitHub).
forge_count_paginated_total() {
  local raw_file="$1"
  jq -s '[.[][]] | length' "${raw_file}"
}

# Fetch recently closed issues.
forge_list_closed_issues() {
  local repo="$1" output_file="$2" limit="$3"
  gh issue list --repo "${repo}" --state closed \
    --json number,title,labels,url --limit "${limit}" \
    > "${output_file}"
}

# Fetch open pull requests. Normalizes output to include headRefName.
forge_list_open_prs() {
  local repo="$1" output_file="$2" limit="$3" token="$4"
  GH_TOKEN="${token}" gh pr list --repo "${repo}" --state open \
    --json number,title,labels,url,headRefName --limit "${limit}" \
    > "${output_file}"
}

# Get repo-level open_issues_count (includes PRs on GitHub) for truncation
# detection. Returns empty string on failure so callers can fall back.
forge_get_issue_count() {
  local repo="$1"
  gh api "repos/${repo}" --jq '.open_issues_count' 2>/dev/null || echo ""
}

# Fetch the repo's doc tree (markdown files under docs/).
forge_get_repo_tree() {
  local repo="$1" token="$2" output_file="$3"
  GH_TOKEN="${token}" gh api "repos/${repo}/git/trees/main?recursive=1" \
    --jq '[.tree[] | select(.path | startswith("docs/") and (.path | endswith(".md"))) | .path]' \
    > "${output_file}" 2>/dev/null || echo '[]' > "${output_file}"
}

# --- Post-script: issue/comment operations ---

# Fetch all comments on an issue (paginated). Returns a flat JSON array.
forge_list_issue_comments() {
  local repo="$1" issue_num="$2"
  gh api --paginate "repos/${repo}/issues/${issue_num}/comments" 2>/dev/null \
    | jq -s '[.[][] | {body}]'
}

# Post a comment on an issue. Body is read from stdin.
forge_post_issue_comment() {
  local repo="$1" issue_num="$2"
  gh issue comment "${issue_num}" --repo "${repo}" --body-file -
}

# Create a new issue with labels. Body is read from stdin. Returns the
# issue URL. Falls back to label-less creation if labels don't exist.
forge_create_issue() {
  local repo="$1" title="$2" labels="$3"
  local url body_file
  body_file=$(mktemp)
  cat > "${body_file}"
  url=$(gh issue create --repo "${repo}" --title "${title}" \
    --label "${labels}" --body-file "${body_file}" 2>/dev/null) || \
  url=$(gh issue create --repo "${repo}" --title "${title}" --body-file "${body_file}")
  rm -f "${body_file}"
  if [[ -z "${url}" ]]; then
    echo "ERROR: forge_create_issue: failed to create issue or missing URL in response" >&2
    return 1
  fi
  echo "${url}"
}

# Return the base URL for linking to issues.
forge_issue_url_base() {
  local repo="$1" server
  server=$(_github_server_url) || return 1
  echo "${server}/${repo}/issues"
}

# Normalize labels for display and creation. Returns comma-separated string.
forge_normalize_labels() {
  local labels="$1"
  printf '%s' "${labels}"
}

# Return the CI run URL for notifications.
forge_run_url() {
  echo "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-${1}}/actions/runs/${GITHUB_RUN_ID:-0}"
}
# END bundled: lib/github-scribe-ops.lib.sh
    ;;
  gitlab)
# BEGIN bundled: lib/gitlab-scribe-ops.lib.sh
# shellcheck shell=bash
# gitlab-scribe-ops.lib.sh — GitLab forge operations for scribe scripts.
#
# Bundled into pre-scribe.sh and post-scribe.sh via scribe-ops.lib.sh.
# All functions use curl against the GitLab REST API.
#
# Expected env vars:
#   SCRIBE_REPO    — GitLab project path (group/project)
#   GITLAB_TOKEN   — GitLab personal/project access token
#   CI_SERVER_HOST — GitLab CI predefined variable (set by runner)
#   CI_SERVER_URL  — GitLab CI predefined variable; origin for API requests
#                    and links, including any non-default port (falls back
#                    to https://${CI_SERVER_HOST} when unset)

[[ -n "${GITLAB_SCRIBE_OPS_SH_LOADED:-}" ]] && return 0
GITLAB_SCRIBE_OPS_SH_LOADED=1

# shellcheck source=gitlab-host-validation.lib.sh
# BEGIN bundled: lib/gitlab-host-validation.lib.sh
# shellcheck shell=bash
# gitlab-host-validation.lib.sh — Shared host validation for GitLab ops.
#
# Validates a hostname against CI_SERVER_HOST, a GitLab CI predefined
# variable set automatically by the runner.
#
# Fails closed: rejects when CI_SERVER_HOST is not set.
#
# Also derives the trusted origin (scheme, host, and optional port) from
# CI_SERVER_URL so self-managed instances on non-default HTTPS ports work.
#
# Sourced by all gitlab-*-ops.lib.sh files and inlined by the bundler.

[[ -n "${GITLAB_HOST_VALIDATION_SH_LOADED:-}" ]] && return 0
GITLAB_HOST_VALIDATION_SH_LOADED=1

if ! declare -F _gha_sanitize >/dev/null 2>&1; then
  _gha_sanitize() {
    printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'
  }
fi

_validate_gitlab_host() {
  local host="$1"
  if [[ -z "${CI_SERVER_HOST:-}" ]]; then
    echo "ERROR: CI_SERVER_HOST is not set (set by GitLab CI runner)" >&2
    return 1
  fi
  if [[ ! "${CI_SERVER_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: CI_SERVER_HOST contains invalid characters" >&2
    return 1
  fi
  if [[ "${host,,}" != "${CI_SERVER_HOST,,}" ]]; then
    echo "ERROR: GitLab host '$(_gha_sanitize "${host}")' does not match CI_SERVER_HOST" >&2
    return 1
  fi
}

# Prints the trusted GitLab origin (https://host[:port]) for API requests
# and generated links. Derived from CI_SERVER_URL, a GitLab CI predefined
# variable that carries any non-default port; falls back to
# https://${CI_SERVER_HOST} when CI_SERVER_URL is unset. Fails closed when
# the origin is not HTTPS or its host does not match CI_SERVER_HOST.
_gitlab_trusted_origin() {
  _validate_gitlab_host "${CI_SERVER_HOST:-}" || return 1
  local origin="${CI_SERVER_URL:-https://${CI_SERVER_HOST}}"
  if [[ ! "${origin}" =~ ^https://([a-zA-Z0-9._-]+)(:[0-9]+)?$ ]]; then
    echo "ERROR: CI_SERVER_URL is not an HTTPS origin (https://host[:port]): $(_gha_sanitize "${origin}")" >&2
    return 1
  fi
  local host="${BASH_REMATCH[1]}"
  _validate_gitlab_host "${host}" || return 1
  printf '%s\n' "${origin}"
}

# Validates an origin (https://host[:port]) parsed from an untrusted URL
# against the trusted CI server origin. Scheme, host, and port must all
# match: a URL without a port only matches a trusted origin without one.
_validate_gitlab_origin() {
  local origin="$1" trusted
  trusted=$(_gitlab_trusted_origin) || return 1
  if [[ "${origin,,}" != "${trusted,,}" ]]; then
    echo "ERROR: GitLab origin '$(_gha_sanitize "${origin}")' does not match CI server origin '$(_gha_sanitize "${trusted}")'" >&2
    return 1
  fi
}
# END bundled: lib/gitlab-host-validation.lib.sh

_gitlab_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  # Scribe has no input URL to cross-reference — uses the trusted CI origin.
  local origin
  origin=$(_gitlab_trusted_origin) || return 1
  curl --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --request "${method}" \
    "${origin}/api/v4${endpoint}" \
    "$@"
}

# Paginate a GitLab GET endpoint, collecting all pages into a single JSON
# array written to the given output file. Uses page-counter increment.
_gitlab_paginate() {
  local endpoint="$1" output_file="$2"
  local page=1 max_pages=100
  local tmp_file
  tmp_file=$(mktemp)
  echo '[]' > "${output_file}"
  while [[ "${page}" -le "${max_pages}" ]]; do
    local sep="?"
    [[ "${endpoint}" == *"?"* ]] && sep="&"
    local batch
    batch=$(_gitlab_api GET "${endpoint}${sep}per_page=100&page=${page}") || { echo "WARNING: _gitlab_paginate: API call failed on page ${page}" >&2; break; }
    local count
    count=$(echo "${batch}" | jq 'length') || break
    [[ "${count}" -eq 0 ]] && break
    jq -s 'add' "${output_file}" <(echo "${batch}") > "${tmp_file}"
    mv "${tmp_file}" "${output_file}"
    page=$((page + 1))
  done
  rm -f "${tmp_file}"
}

# --- Pre-script: repo context ---

# Fetch all open issues (paginated). GitLab's /issues endpoint does NOT
# include merge requests — no PR filtering needed. Output is saved as a
# flat JSON array matching the GitHub raw format for downstream processing.
forge_fetch_open_issues_raw() {
  local repo="$1" output_file="$2"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  _gitlab_paginate "/projects/${repo_encoded}/issues?state=opened&order_by=created_at&sort=desc" "${output_file}"
}

# Filter/normalize raw issues into the backlog format. GitLab fields are
# normalized to match the GitHub output schema: iid→number,
# description→body, web_url→url, labels (strings)→label objects.
forge_filter_issues_to_backlog() {
  local raw_file="$1" backlog_file="$2"
  jq '[.[] | {
    number: .iid,
    title,
    body: (.description // ""),
    labels: [.labels[]? | {name: .}],
    milestone,
    url: .web_url
  } | .body = ((.body // "")[:500] + if ((.body // "") | length) > 500 then "…" else "" end)]' \
    "${raw_file}" > "${backlog_file}"
}

# Count total paginated items. On GitLab, the issues endpoint only returns
# issues (no MRs), so this equals the issue count.
forge_count_paginated_total() {
  local raw_file="$1"
  jq 'length' "${raw_file}"
}

# Fetch recently closed issues, normalized to common schema.
forge_list_closed_issues() {
  local repo="$1" output_file="$2" limit="$3"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  _gitlab_api GET "/projects/${repo_encoded}/issues?state=closed&order_by=updated_at&sort=desc&per_page=${limit}" 2>/dev/null \
    | jq '[.[] | {
        number: .iid,
        title,
        labels: [.labels[]? | {name: .}],
        url: .web_url
      }]' > "${output_file}" || echo '[]' > "${output_file}"
}

# Fetch open merge requests, normalized to match the PR schema. The
# source_branch field is mapped to headRefName for forge-neutral agent use.
forge_list_open_prs() {
  local repo="$1" output_file="$2" limit="$3" _token="$4"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  _gitlab_api GET "/projects/${repo_encoded}/merge_requests?state=opened&per_page=${limit}" 2>/dev/null \
    | jq '[.[] | {
        number: .iid,
        title,
        labels: [.labels[]? | {name: .}],
        url: .web_url,
        headRefName: .source_branch
      }]' > "${output_file}" || echo '[]' > "${output_file}"
}

# Get the project's open_issues_count (issues only on GitLab, no MRs).
forge_get_issue_count() {
  local repo="$1"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  _gitlab_api GET "/projects/${repo_encoded}" 2>/dev/null \
    | jq '.open_issues_count // empty' 2>/dev/null || echo ""
}

# Fetch the repo's doc tree (markdown files under docs/).
forge_get_repo_tree() {
  local repo="$1" _token="$2" output_file="$3"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  local tmp_file
  tmp_file=$(mktemp)
  _gitlab_paginate "/projects/${repo_encoded}/repository/tree?recursive=true&ref=main" "${tmp_file}"
  jq '[.[] | select(.path | startswith("docs/") and (.path | endswith(".md"))) | .path]' \
    "${tmp_file}" > "${output_file}" 2>/dev/null || echo '[]' > "${output_file}"
  rm -f "${tmp_file}"
}

# --- Post-script: issue/comment operations ---

# Fetch all notes (comments) on an issue. Returns a flat JSON array
# with field projection to match the GitHub comments shape.
forge_list_issue_comments() {
  local repo="$1" issue_num="$2"
  local repo_encoded
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  local tmp_file
  tmp_file=$(mktemp)
  trap 'rm -f "${tmp_file}"' RETURN
  _gitlab_paginate "/projects/${repo_encoded}/issues/${issue_num}/notes?sort=asc" "${tmp_file}"
  jq '[.[] | select(.system != true) | {body}]' "${tmp_file}"
}

# Post a note (comment) on an issue. Body is read from stdin.
forge_post_issue_comment() {
  local repo="$1" issue_num="$2"
  local repo_encoded body_file rc=0
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  body_file=$(mktemp)
  cat > "${body_file}"
  _gitlab_api POST "/projects/${repo_encoded}/issues/${issue_num}/notes" \
    --data-urlencode "body@${body_file}" > /dev/null || rc=$?
  rm -f "${body_file}"
  return "${rc}"
}

# Create a new issue with labels. Body is read from stdin. Returns the
# issue web URL.
forge_create_issue() {
  local repo="$1" title="$2" labels="$3"
  local repo_encoded body_file
  repo_encoded=$(printf '%s' "${repo}" | jq -sRr @uri)
  body_file=$(mktemp)
  cat > "${body_file}"
  local response
  response=$(_gitlab_api POST "/projects/${repo_encoded}/issues" \
    --data-urlencode "title=${title}" \
    --data-urlencode "labels=${labels}" \
    --data-urlencode "description@${body_file}" 2>/dev/null) || \
  response=$(_gitlab_api POST "/projects/${repo_encoded}/issues" \
    --data-urlencode "title=${title}" \
    --data-urlencode "description@${body_file}")
  rm -f "${body_file}"
  local url
  url=$(echo "${response}" | jq -r '.web_url // empty')
  if [[ -z "${url}" ]]; then
    echo "ERROR: forge_create_issue: failed to create issue or missing web_url in response" >&2
    return 1
  fi
  echo "${url}"
}

# Return the base URL for linking to issues.
forge_issue_url_base() {
  local repo="$1" origin
  origin=$(_gitlab_trusted_origin) || return 1
  echo "${origin}/${repo}/-/issues"
}

# Normalize labels for display and creation. Returns comma-separated string.
forge_normalize_labels() {
  local labels="$1"
  printf '%s' "${labels}"
}

# Return the CI run/job URL for notifications.
forge_run_url() {
  if [[ -n "${CI_JOB_URL:-}" ]]; then
    echo "${CI_JOB_URL}"
  else
    local origin
    origin=$(_gitlab_trusted_origin) || return 1
    echo "${origin}/${1}"
  fi
}
# END bundled: lib/gitlab-scribe-ops.lib.sh
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
# BEGIN bundled: lib/jira-scribe-ops.lib.sh
# shellcheck shell=bash
# jira-scribe-ops.lib.sh — Jira Cloud tracker operations for scribe scripts.
#
# Bundled into pre-scribe.sh and post-scribe.sh via scribe-ops.lib.sh, which
# sources this file AFTER the GitHub/GitLab forge library when
# FULLSEND_TRACKER=jira. The functions below redefine the backlog, closed-issue,
# and write operations (open-issue fetch, backlog filter, closed-issue fetch,
# open count, issue creation, issue URL base) so that backlog matching,
# closed-issue context, and writes target one Jira project, while repo context
# (open PRs, doc index, run URL) keeps coming from the forge.
#
# Scope (MVP): new issues only, in one operator-configured project and
# issue type. Comment writes are not supported — existing_issue is a
# numeric forge issue number and Jira keys need a separate string-key path.
#
# All writes happen host-side in post-scribe.sh with operator-provided
# credentials; the sandbox never receives the Jira token.
#
# Jira Cloud only: JIRA_BASE_URL must be https://<site>.atlassian.net.
#
# Requires fullsend >= the release that ships `fullsend issues create
# --tracker jira --fullsend-dir` (fullsend#7083 / fullsend#9078). The post-script
# validates this at preflight time via tracker_validate_create.
#
# Expected env vars:
#   JIRA_BASE_URL          — Jira Cloud base URL (https://<site>.atlassian.net)
#   JIRA_TOKEN             — Jira API token. Or, instead of it:
#   FULLSEND_JIRA_CLIENT_ID, FULLSEND_JIRA_CLIENT_SECRET
#                          — service-account OAuth 2.0 client credentials.
#                            REST calls then use an access token minted on
#                            the runner and need JIRA_API_URL. Setting both
#                            modes fails.
#   FULLSEND_DIR           — .fullsend directory whose config.yaml holds
#                            tracker.jira, for `fullsend issues create`
#   SCRIBE_JIRA_PROJECT    — Jira project key that backlog reads and new
#                            issues are scoped to (e.g. "PROJ")
#
# Optional env vars:
#   JIRA_USER_EMAIL        — bot-user email. When set, requests use Basic
#                            auth with email and token; when unset or empty,
#                            Bearer auth with a service-account token. See
#                            lib/jira-auth.lib.sh.
#   JIRA_API_URL           — where REST calls go, e.g. the Atlassian API
#                            gateway https://api.atlassian.com/ex/jira/<cloudId>
#                            that `fullsend run` resolves and exports. Falls
#                            back to JIRA_BASE_URL when unset (older fullsend
#                            releases). Required with client credentials:
#                            scribe runs are not Jira-sourced, so `fullsend
#                            run` does not set it and the operator must.
#                            Browse links always use JIRA_BASE_URL.
#   SCRIBE_JIRA_ISSUE_TYPE — issue type name for created issues (default: "Task")
#   SCRIBE_JIRA_LABELS     — comma-separated allowlist of labels that scribe may
#                            apply to Jira issues (default: "meeting-notes")
#   SCRIBE_JIRA_MAX_PAGES  — maximum pages fetched per paginated Jira read
#                            (default: 50)

[[ -n "${JIRA_SCRIBE_OPS_SH_LOADED:-}" ]] && return 0
JIRA_SCRIBE_OPS_SH_LOADED=1

# JIRA_USER_EMAIL is optional: without it, requests use Bearer auth.
# shellcheck source=jira-auth.lib.sh
# BEGIN bundled: lib/jira-auth.lib.sh
# shellcheck shell=bash
# jira-auth.lib.sh — Jira credential-mode selection for host-side scripts.
#
# Shared by the Jira triage and scribe ops libraries and post-code.sh, and
# bundled into each script that sources it. Three credential modes
# (fullsend#9007, agents#1926):
#
#   token + email      — bot user: Basic auth with email:token
#   token only         — service account: Bearer auth with the token
#   client credentials — service account OAuth 2.0 client credentials
#                        (FULLSEND_JIRA_CLIENT_ID and
#                        FULLSEND_JIRA_CLIENT_SECRET): REST calls use a
#                        Bearer access token minted on the runner, and the
#                        fullsend CLI gets the client credentials and mints
#                        for itself
#
# An email that is empty or only whitespace counts as absent. A harness
# that maps an unset FULLSEND_JIRA_EMAIL to JIRA_USER_EMAIL yields an empty
# string, and that must select Bearer, never an empty-user Basic header.
#
# Every helper takes the token and email as arguments, so callers that
# withhold the credentials from their environment can pass saved copies.
# jira_auth_select chooses the mode once; until it is called, the helpers
# use the token and email they are given (the token modes).
#
# The client secret is kept in shell variables only. It never reaches a
# command line, a file, the output, or an xtrace line: jira_auth_select
# takes the names of the client ID and secret variables and reads them
# with xtrace off, jq builds the token request body from its environment
# and sends it to curl on stdin, and a failed request reports its HTTP
# status, never the response body.

[[ -n "${JIRA_AUTH_SH_LOADED:-}" ]] && return 0
JIRA_AUTH_SH_LOADED=1

# Selected mode: "token", "client", or "none". Empty until jira_auth_select.
JIRA_AUTH_MODE=""
_JIRA_AUTH_CLIENT_ID=""
_JIRA_AUTH_CLIENT_SECRET=""
_JIRA_AUTH_ACCESS_TOKEN=""
_JIRA_AUTH_EXPIRES_AT=0

# Print the argument with surrounding whitespace removed.
_jira_auth_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# Print the email with surrounding whitespace removed. Empty output means
# no email, which selects Bearer auth.
#
# Usage: jira_auth_email <email>
jira_auth_email() {
  local email="$1"
  email="${email#"${email%%[![:space:]]*}"}"
  email="${email%"${email##*[![:space:]]}"}"
  printf '%s' "${email}"
}

# Select the credential mode and set JIRA_AUTH_MODE:
#   token  — a token is set (the email decides Basic or Bearer per call)
#   client — the client ID and secret are both set and no token is
#   none   — nothing is set
# The client ID and secret are passed as variable names, never values, so
# a traced call line shows only the names; they are read with xtrace off.
# Fails, naming the variables but never their values, when a token and
# client credentials are both set, only one client variable is, or a name
# is not a shell identifier. Values are trimmed, so one that is only
# whitespace counts as unset.
#
# Usage: jira_auth_select <token> <client-id-var> <client-secret-var>
jira_auth_select() {
  local _jas_xtrace=0 _jas_rc=0
  if [[ $- == *x* ]]; then
    _jas_xtrace=1
    set +x
  fi
  _jira_auth_select_now "$@" || _jas_rc=$?
  if [[ "${_jas_xtrace}" -eq 1 ]]; then
    set -x
  fi
  return "${_jas_rc}"
}

# Locals use a _jas_ prefix, and such names are refused, so the indirect
# reads see the caller's variables, not these.
_jira_auth_select_now() {
  local _jas_name
  for _jas_name in "$2" "$3"; do
    if [[ ! "${_jas_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ || "${_jas_name}" == _jas_* ]]; then
      echo "ERROR: jira_auth_select needs the names of the client ID and secret variables" >&2
      return 1
    fi
  done
  local _jas_token _jas_id _jas_secret
  _jas_token="$(_jira_auth_trim "$1")"
  _jas_id="$(_jira_auth_trim "${!2:-}")"
  _jas_secret="$(_jira_auth_trim "${!3:-}")"
  if [[ -n "${_jas_token}" && ( -n "${_jas_id}" || -n "${_jas_secret}" ) ]]; then
    echo "ERROR: set either FULLSEND_JIRA_TOKEN (JIRA_TOKEN) or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET, not both" >&2
    return 1
  fi
  if [[ -n "${_jas_id}" && -z "${_jas_secret}" ]] || [[ -z "${_jas_id}" && -n "${_jas_secret}" ]]; then
    echo "ERROR: FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET must be set together" >&2
    return 1
  fi
  _JIRA_AUTH_ACCESS_TOKEN=""
  _JIRA_AUTH_EXPIRES_AT=0
  if [[ -n "${_jas_token}" ]]; then
    JIRA_AUTH_MODE="token"
  elif [[ -n "${_jas_id}" ]]; then
    JIRA_AUTH_MODE="client"
    _JIRA_AUTH_CLIENT_ID="${_jas_id}"
    _JIRA_AUTH_CLIENT_SECRET="${_jas_secret}"
  else
    JIRA_AUTH_MODE="none"
  fi
}

# In client-credentials mode, fail unless JIRA_API_URL is set. A minted
# access token works only through the Atlassian API gateway
# (https://api.atlassian.com/ex/jira/<cloudId>); the site URL in
# JIRA_BASE_URL rejects it, so there is no fallback.
#
# Usage: jira_auth_require_api_url
jira_auth_require_api_url() {
  if [[ "${JIRA_AUTH_MODE}" == "client" && -z "${JIRA_API_URL:-}" ]]; then
    echo "ERROR: JIRA_API_URL (the Atlassian API gateway URL) must be set when FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET are used; JIRA_BASE_URL does not accept their access tokens" >&2
    return 1
  fi
}

# In client-credentials mode, make sure a usable access token is held:
# mint one when there is none or it expires within 5 minutes. A no-op in
# the other modes. The token is kept in a shell variable only and masked
# before anything else is printed. Mint once in the script's own shell,
# with stdout not redirected, so the mask line reaches the log and later
# calls, including those in command substitutions, reuse the token.
#
# Usage: jira_auth_mint
jira_auth_mint() {
  [[ "${JIRA_AUTH_MODE}" == "client" ]] || return 0
  local now
  now="$(date +%s)"
  if [[ -n "${_JIRA_AUTH_ACCESS_TOKEN}" ]] && (( now < _JIRA_AUTH_EXPIRES_AT - 300 )); then
    return 0
  fi
  local xtrace=0 rc=0
  if [[ $- == *x* ]]; then
    xtrace=1
    set +x
  fi
  _jira_auth_mint_now "${now}" || rc=$?
  if [[ "${xtrace}" -eq 1 ]]; then
    set -x
  fi
  return "${rc}"
}

# Request an access token the way fullsend does
# (internal/forge/jira/oauth.go). Called by jira_auth_mint with xtrace off.
# jq builds the body from the trimmed ID and secret in its environment and
# curl reads it on stdin; curl -q ignores curl config files.
_jira_auth_mint_now() {
  local now="$1"
  local raw rc=0
  raw="$(_JIRA_AUTH_ID="${_JIRA_AUTH_CLIENT_ID}" \
    _JIRA_AUTH_SECRET="${_JIRA_AUTH_CLIENT_SECRET}" \
    jq -cn '{grant_type: "client_credentials", client_id: env._JIRA_AUTH_ID, client_secret: env._JIRA_AUTH_SECRET}' \
    | curl -q --proto =https --silent --connect-timeout 10 --max-time 30 \
      --header "Content-Type: application/json" \
      --data @- \
      --write-out '\n%{http_code}' \
      "https://auth.atlassian.com/oauth/token" 2>/dev/null)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "ERROR: Jira OAuth token request failed (curl exit ${rc})" >&2
    return 1
  fi
  local http_code="${raw##*$'\n'}"
  local body="${raw%$'\n'*}"
  [[ "${http_code}" =~ ^[0-9]{3}$ ]] || http_code="unknown"
  if [[ "${http_code}" != 2?? ]]; then
    echo "ERROR: Jira OAuth token request failed (HTTP ${http_code})" >&2
    return 1
  fi
  local token expires_in
  token="$(printf '%s' "${body}" | jq -r '.access_token // empty' 2>/dev/null)" || token=""
  expires_in="$(printf '%s' "${body}" | jq -r '.expires_in // empty' 2>/dev/null)" || expires_in=""
  # Atlassian access tokens are JWTs. Anything outside this charset could
  # break or inject into the ::add-mask:: line, so it is refused unprinted.
  if [[ ! "${token}" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    echo "ERROR: Jira OAuth token response has no usable access_token" >&2
    return 1
  fi
  # In the script's own shell the mask goes to stdout. In a subshell, such
  # as a command substitution, stdout may be captured, so it goes to the
  # main shell's current stdout through /proc when that is a pipe or a
  # terminal (the runner log), else to stderr. A file or /dev/null there
  # means the caller redirected stdout around the call.
  local main_out="/proc/$$/fd/1"
  if (( BASH_SUBSHELL == 0 )); then
    printf '::add-mask::%s\n' "${token}"
  elif [[ -w "${main_out}" ]] && [[ -p "${main_out}" || -c "${main_out}" ]] \
    && ! [[ "${main_out}" -ef /dev/null ]]; then
    printf '::add-mask::%s\n' "${token}" >> "${main_out}"
  else
    printf '::add-mask::%s\n' "${token}" >&2
  fi
  [[ "${expires_in}" =~ ^[0-9]+$ ]] || expires_in=3600
  _JIRA_AUTH_ACCESS_TOKEN="${token}"
  _JIRA_AUTH_EXPIRES_AT=$((now + expires_in))
}

# Run curl with the Authorization for the selected mode, followed by the
# caller's arguments. In client-credentials mode the token and email
# arguments are ignored and the minted access token is sent as Bearer.
# Otherwise fails without calling curl when the token is empty.
#
# Usage: jira_auth_curl <token> <email> [curl args...]
jira_auth_curl() {
  local token="$1"
  local email
  email="$(jira_auth_email "$2")"
  shift 2
  if [[ "${JIRA_AUTH_MODE}" == "client" ]]; then
    jira_auth_mint || return 1
    curl --oauth2-bearer "${_JIRA_AUTH_ACCESS_TOKEN}" "$@"
    return
  fi
  if [[ -z "${token}" ]]; then
    echo "ERROR: Jira token is empty" >&2
    return 1
  fi
  if [[ -n "${email}" ]]; then
    curl --user "${email}:${token}" "$@"
  else
    curl --oauth2-bearer "${token}" "$@"
  fi
}

# Run the fullsend CLI with the Jira credentials it reads from its
# environment: FULLSEND_JIRA_TOKEN always, FULLSEND_JIRA_EMAIL only for a
# bot user. In Bearer mode an inherited FULLSEND_JIRA_EMAIL is removed, so
# the CLI cannot pick Basic auth. In client-credentials mode the CLI gets
# FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET, with
# FULLSEND_JIRA_TOKEN and FULLSEND_JIRA_EMAIL removed, and mints for
# itself, with xtrace off. The values go through the environment, never
# the command line.
#
# Usage: jira_auth_fullsend <fullsend-bin> <token> <email> [cli args...]
jira_auth_fullsend() {
  local bin="$1"
  local token="$2"
  local email
  email="$(jira_auth_email "$3")"
  shift 3
  if [[ "${JIRA_AUTH_MODE}" == "client" ]]; then
    local xtrace=0 rc=0
    if [[ $- == *x* ]]; then
      xtrace=1
      set +x
    fi
    (
      unset FULLSEND_JIRA_TOKEN FULLSEND_JIRA_EMAIL
      FULLSEND_JIRA_CLIENT_ID="${_JIRA_AUTH_CLIENT_ID}" \
        FULLSEND_JIRA_CLIENT_SECRET="${_JIRA_AUTH_CLIENT_SECRET}" "${bin}" "$@"
    ) || rc=$?
    if [[ "${xtrace}" -eq 1 ]]; then
      set -x
    fi
    return "${rc}"
  fi
  if [[ -z "${token}" ]]; then
    echo "ERROR: Jira token is empty" >&2
    return 1
  fi
  if [[ -n "${email}" ]]; then
    FULLSEND_JIRA_TOKEN="${token}" FULLSEND_JIRA_EMAIL="${email}" "${bin}" "$@"
  else
    (
      unset FULLSEND_JIRA_EMAIL
      FULLSEND_JIRA_TOKEN="${token}" "${bin}" "$@"
    )
  fi
}
# END bundled: lib/jira-auth.lib.sh
jira_auth_select "${JIRA_TOKEN:-}" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET || exit 1
if [[ "${JIRA_AUTH_MODE}" == "none" ]]; then
  echo "ERROR: JIRA_TOKEN must be set, or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET" >&2
  exit 1
fi
: "${JIRA_BASE_URL:?JIRA_BASE_URL must be set}"
: "${SCRIBE_JIRA_PROJECT:?SCRIBE_JIRA_PROJECT must be set}"
jira_auth_require_api_url || exit 1

while [[ "${JIRA_BASE_URL}" == */ ]]; do
  JIRA_BASE_URL="${JIRA_BASE_URL%/}"
done
if [[ ! "${JIRA_BASE_URL}" =~ ^https://[a-zA-Z0-9-]+\.atlassian\.net$ ]]; then
  echo "ERROR: JIRA_BASE_URL must be a Jira Cloud URL (https://<site>.atlassian.net)" >&2
  exit 1
fi
# Base URL for REST calls; the credentials go here, so require https.
SCRIBE_JIRA_API_BASE="${JIRA_API_URL:-${JIRA_BASE_URL}}"
while [[ "${SCRIBE_JIRA_API_BASE}" == */ ]]; do
  SCRIBE_JIRA_API_BASE="${SCRIBE_JIRA_API_BASE%/}"
done
if [[ "${SCRIBE_JIRA_API_BASE}" != https://* ]]; then
  echo "ERROR: JIRA_API_URL must start with https://" >&2
  exit 1
fi
if [[ ! "${SCRIBE_JIRA_PROJECT}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
  echo "ERROR: SCRIBE_JIRA_PROJECT must be a Jira project key (e.g. PROJ)" >&2
  exit 1
fi
SCRIBE_JIRA_ISSUE_TYPE="${SCRIBE_JIRA_ISSUE_TYPE:-Task}"
SCRIBE_JIRA_LABELS="${SCRIBE_JIRA_LABELS:-meeting-notes}"

# Maximum pages fetched per paginated Jira read (100 issues per JQL page).
SCRIBE_JIRA_MAX_PAGES="${SCRIBE_JIRA_MAX_PAGES:-50}"
# Client credentials: mint the access token here, in the script's own
# shell, so later REST calls reuse it. A failure is reported here and each
# REST call then fails on its own.
jira_auth_mint || true

_scribe_jira_api() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  jira_auth_curl "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    --fail --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --request "${method}" \
    "${SCRIBE_JIRA_API_BASE}/rest/api/3${endpoint}" \
    "$@"
}

# Like _scribe_jira_api but captures the HTTP status code and returns the
# response body even on error, so callers can log field-level rejection
# reasons instead of a generic "failed" message.
_scribe_jira_api_with_status() {
  local method="$1"
  shift
  local endpoint="$1"
  shift
  local err_file raw http_code body
  err_file=$(mktemp)
  raw=$(jira_auth_curl "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --request "${method}" \
    --write-out '\n%{http_code}' \
    "${SCRIBE_JIRA_API_BASE}/rest/api/3${endpoint}" \
    "$@" 2>"${err_file}") || {
    echo "Jira API error: curl failed — $(_gha_sanitize "$(grep -v '^::add-mask::' "${err_file}")")" >&2
    rm -f "${err_file}"
    return 1
  }
  rm -f "${err_file}"
  http_code=$(printf '%s' "${raw}" | tail -1)
  body=$(printf '%s' "${raw}" | sed '$d')
  if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
    local errors
    errors=$(printf '%s' "${body}" | jq -r '(.errorMessages // []) + [(.errors // {} | to_entries[] | "\(.key): \(.value)")] | join("; ")' 2>/dev/null || echo "")
    echo "Jira API error (HTTP ${http_code}): $(_gha_sanitize "${errors:-${body}}")" >&2
    return 1
  fi
  printf '%s' "${body}"
}

# Escape a value for use inside a double-quoted JQL string literal.
_scribe_jql_quote() {
  local val="$1"
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  printf '"%s"' "${val}"
}

_scribe_jira_backlog_jql() {
  printf 'project = %s AND statusCategory != Done ORDER BY created DESC' \
    "$(_scribe_jql_quote "${SCRIBE_JIRA_PROJECT}")"
}

_scribe_jira_closed_jql() {
  printf 'project = %s AND statusCategory = Done AND resolved >= -30d ORDER BY resolved DESC' \
    "$(_scribe_jql_quote "${SCRIBE_JIRA_PROJECT}")"
}

# Run a JQL search, following nextPageToken. Writes one JSON array of issues
# per page to output_file (same multi-document shape as `gh api --paginate`).
# Returns 2 if the page cap was hit while more results remained.
_scribe_jira_search_paginated() {
  local jql="$1" fields_json="$2" output_file="$3"
  local token="" page payload response is_last
  : > "${output_file}"
  for ((page = 1; page <= SCRIBE_JIRA_MAX_PAGES; page++)); do
    payload=$(jq -cn --arg jql "${jql}" --argjson fields "${fields_json}" --arg tok "${token}" \
      '{jql: $jql, fields: $fields, maxResults: 100} + (if $tok != "" then {nextPageToken: $tok} else {} end)')
    response=$(_scribe_jira_api POST "/search/jql" --data "${payload}") || {
      echo "ERROR: Jira JQL search failed" >&2
      return 1
    }
    # A 2xx response that is not JSON, or has no issues array, must not be
    # read as "no results" — callers use that to prove a duplicate is absent.
    if ! printf '%s' "${response}" | jq -ce 'select(type == "object" and (.issues | type) == "array") | .issues' >> "${output_file}"; then
      echo "ERROR: Jira JQL search returned a malformed or incomplete response" >&2
      return 1
    fi
    token=$(printf '%s' "${response}" | jq -r '.nextPageToken // empty') || {
      echo "ERROR: Jira JQL search response could not be parsed" >&2
      return 1
    }
    is_last=$(printf '%s' "${response}" | jq -r '.isLast // false') || {
      echo "ERROR: Jira JQL search response could not be parsed" >&2
      return 1
    }
    if [[ "${is_last}" == "true" ]]; then
      return 0
    fi
    if [[ -z "${token}" ]]; then
      echo "ERROR: Jira JQL search returned isLast=false with no nextPageToken" >&2
      return 1
    fi
  done
  echo "WARNING: Jira search stopped after ${SCRIBE_JIRA_MAX_PAGES} pages; results are truncated" >&2
  return 2
}

# --- Pre-script: backlog ---

forge_fetch_open_issues_raw() {
  local _repo="$1" output_file="$2" rc=0
  _scribe_jira_search_paginated "$(_scribe_jira_backlog_jql)" \
    '["summary","description","labels","status"]' "${output_file}" || rc=$?
  if [[ ${rc} -eq 2 ]]; then
    # shellcheck disable=SC2034 # SCRIBE_BACKLOG_PAGE_CAPPED consumed by pre-scribe
    SCRIBE_BACKLOG_PAGE_CAPPED=true
    return 2
  fi
  return ${rc}
}

# Convert raw Jira issues to the backlog format. Jira issues carry a string
# `key` instead of a numeric `number`; the description (ADF) is flattened
# to plain text and truncated to 500 chars.
forge_filter_issues_to_backlog() {
  local raw_file="$1" backlog_file="$2"
  jq -s --arg base "${JIRA_BASE_URL}" '[.[][] | {
      key,
      title: (.fields.summary // ""),
      body: ([.fields.description | .. | objects | select(.type == "text") | .text] | join(" ")),
      labels: (.fields.labels // []),
      url: ($base + "/browse/" + .key)
    }]' "${raw_file}" \
    | jq '[.[] | .body = (.body[:500] + if (.body | length) > 500 then "…" else "" end)]' \
    > "${backlog_file}"
}

forge_count_paginated_total() {
  local raw_file="$1"
  jq -s '[.[][]] | length' "${raw_file}"
}

# Approximate open-issue count for truncation detection. Returns empty on
# failure so callers fall back to the fetched count.
forge_get_issue_count() {
  local _repo="$1"
  _scribe_jira_api POST "/search/approximate-count" \
    --data "$(jq -cn --arg jql "$(_scribe_jira_backlog_jql)" '{jql: $jql}')" 2>/dev/null \
    | jq -r '.count // empty' 2>/dev/null || echo ""
}

# Fetch recently closed (Done) issues from the Jira project (resolved in the
# last 30 days, up to limit, default 50).
forge_list_closed_issues() {
  local _repo="$1" output_file="$2" limit="${3:-50}"
  [[ "${limit}" =~ ^[1-9][0-9]*$ ]] || limit=50
  [[ "${limit}" -gt 100 ]] && limit=100
  local payload response
  payload=$(jq -cn \
    --arg jql "$(_scribe_jira_closed_jql)" \
    --argjson limit "${limit}" \
    '{jql: $jql, fields: ["summary","labels"], maxResults: $limit}')
  response=$(_scribe_jira_api POST "/search/jql" --data "${payload}" 2>/dev/null) || {
    echo "WARNING: failed to fetch recently closed Jira issues" >&2
    echo '[]' > "${output_file}"
    return 0
  }
  if ! printf '%s' "${response}" | jq --arg base "${JIRA_BASE_URL}" '[.issues[]? | {
      key,
      title: (.fields.summary // ""),
      labels: (.fields.labels // []),
      url: ($base + "/browse/" + .key)
    }]' > "${output_file}" 2>/dev/null; then
    echo "WARNING: failed to parse recently closed Jira issues" >&2
    echo '[]' > "${output_file}"
    return 0
  fi
}

# --- Post-script: issue operations ---

forge_list_issue_comments() {
  echo "ERROR: comments are not supported when FULLSEND_TRACKER=jira" >&2
  return 1
}

forge_post_issue_comment() {
  echo "ERROR: comments are not supported when FULLSEND_TRACKER=jira" >&2
  return 1
}

# Filter and sanitize labels for Jira:
# 1. Accepts either a JSON array or a comma-separated list.
# 2. Intersects with the operator allowlist SCRIBE_JIRA_LABELS (default: "meeting-notes").
# 3. Enforces ^[A-Za-z0-9._-]{1,64}$ per label.
# 4. Caps at 10 labels and deduplicates while preserving order.
_scribe_jira_filter_labels() {
  local raw="$1"
  jq -cn \
    --arg raw "${raw}" \
    --arg allowlist "${SCRIBE_JIRA_LABELS:-meeting-notes}" '
    def parse_list:
      if (type == "array") then .
      elif (type == "string") then [split(",")[] | gsub("^\\s+|\\s+$"; "")]
      else [] end;
    def parse_raw:
      ($raw | try fromjson catch $raw) | parse_list;
    def parse_allowlist:
      $allowlist | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(test("^[A-Za-z0-9._-]{1,64}$")));
    (parse_allowlist) as $allowed |
    [parse_raw[]?
      | select(type == "string")
      | gsub("^\\s+|\\s+$"; "")
      | select(test("^[A-Za-z0-9._-]{1,64}$"))
      | select(. as $item | $allowed | index($item))
    ] | reduce .[] as $item ([]; if index($item) then . else . + [$item] end) | .[0:10]
  '
}

# Add labels to an existing Jira issue via the REST API. Labels can be
# passed as a JSON array or a comma-separated list. Labels are filtered
# through _scribe_jira_filter_labels (allowlist, format, count cap).
_scribe_jira_add_labels() {
  local key="$1" labels="$2"
  local labels_json ops
  labels_json=$(_scribe_jira_filter_labels "${labels}")
  if [[ "$(printf '%s' "${labels_json}" | jq 'length')" -eq 0 ]]; then
    return 0
  fi
  ops=$(printf '%s' "${labels_json}" | jq '{update:{labels:[.[] | {add:.}]}}')
  _scribe_jira_api_with_status PUT "/issue/${key}" --data "${ops}" > /dev/null
}

# Fetch every item of a paginated createmeta endpoint (startAt paging) and
# print them as one JSON array. Fails if a page cannot be read or the page
# cap is hit before the last page, so callers never validate on partial data.
_scribe_jira_createmeta_all() {
  local endpoint="$1" start=0 page resp count total last
  local items_file
  items_file=$(mktemp)
  printf '[]' > "${items_file}"
  for ((page = 1; page <= SCRIBE_JIRA_MAX_PAGES; page++)); do
    resp=$(_scribe_jira_api GET "${endpoint}?maxResults=200&startAt=${start}") || { rm -f "${items_file}"; return 1; }
    count=$(printf '%s' "${resp}" | jq -r '(.issueTypes // .values // .fields // []) | length') || { rm -f "${items_file}"; return 1; }
    # Merge page items via stdin/file to avoid --argjson argument-size limits
    # on projects with large allowedValues lists. Strip allowedValues to
    # reduce accumulated size since it is not needed for validation.
    if printf '%s' "${resp}" | jq -c '(.issueTypes // .values // .fields // []) | map(del(.allowedValues))' \
      | jq -sc '.[0] + .[1]' "${items_file}" - > "${items_file}.tmp" \
      && mv "${items_file}.tmp" "${items_file}"; then
      :
    else
      rm -f "${items_file}" "${items_file}.tmp"
      return 1
    fi
    total=$(printf '%s' "${resp}" | jq -r '.total // empty')
    # Distinguish absent isLast from explicit false: jq's `// empty`
    # converts false to empty, so use has() to detect absence.
    last=$(printf '%s' "${resp}" | jq -r 'if has("isLast") then (.isLast | tostring) else "absent" end')
    start=$((start + count))
    # Without a total or isLast marker the response is a single page.
    if [[ "${count}" -eq 0 || "${last}" == "true" ]] \
      || [[ -z "${total}" && "${last}" == "absent" ]] \
      || [[ -n "${total}" && "${start}" -ge "${total}" ]]; then
      cat "${items_file}"
      rm -f "${items_file}"
      return 0
    fi
  done
  rm -f "${items_file}"
  echo "ERROR: Jira create metadata exceeds ${SCRIBE_JIRA_MAX_PAGES} pages" >&2
  return 1
}

# Check that the configured project and issue type exist and that every
# required create field without a default is one scribe supplies. Fails
# before any create call when the project needs extra fields.
tracker_validate_create() {
  local types type_id meta missing
  # Preflight: verify that the fullsend CLI ships `issues create`.
  # The config-backed form (--tracker jira --fullsend-dir) was introduced in
  # fullsend#9078 and may not be present in older binaries. Failing here surfaces the problem on
  # dry-run instead of silently passing validation and then exploding
  # on the first live create.
  if ! fullsend issues create --help >/dev/null 2>&1; then
    echo "ERROR: 'fullsend issues create' is not available — upgrade fullsend to a version that includes the config-backed Jira commands (fullsend#9078)" >&2
    return 1
  fi
  types=$(_scribe_jira_createmeta_all "/issue/createmeta/${SCRIBE_JIRA_PROJECT}/issuetypes") || {
    echo "ERROR: cannot read create metadata for Jira project ${SCRIBE_JIRA_PROJECT} (missing project or no create permission)" >&2
    return 1
  }
  type_id=$(printf '%s' "${types}" | jq -r --arg name "${SCRIBE_JIRA_ISSUE_TYPE}" \
    '[.[] | select(.name == $name)][0].id // empty')
  if [[ -z "${type_id}" ]]; then
    echo "ERROR: issue type '$(_gha_sanitize "${SCRIBE_JIRA_ISSUE_TYPE}")' is not available in Jira project ${SCRIBE_JIRA_PROJECT}" >&2
    return 1
  fi
  meta=$(_scribe_jira_createmeta_all "/issue/createmeta/${SCRIBE_JIRA_PROJECT}/issuetypes/${type_id}") || {
    echo "ERROR: cannot read create fields for issue type '$(_gha_sanitize "${SCRIBE_JIRA_ISSUE_TYPE}")' in Jira project ${SCRIBE_JIRA_PROJECT}" >&2
    return 1
  }
  missing=$(printf '%s' "${meta}" | jq -r '
    [.[]
      | select(.required == true and (.hasDefaultValue // false) == false)
      | select((.fieldId // .key) as $f | ["project","issuetype","summary","description"] | index($f) | not)
      | (.fieldId // .key)] | join(", ")')
  if [[ -n "${missing}" ]]; then
    echo "ERROR: Jira project ${SCRIBE_JIRA_PROJECT} requires fields scribe does not set: $(_gha_sanitize "${missing}")" >&2
    return 1
  fi
  # forge_create_issue sends description and labels; Jira rejects the create
  # when a field is not on the create screen. Description carries the issue
  # content, so fail clearly; labels are optional, so omit them instead.
  if ! printf '%s' "${meta}" | jq -e 'any(.[]; (.fieldId // .key) == "description")' >/dev/null; then
    echo "ERROR: issue type '$(_gha_sanitize "${SCRIBE_JIRA_ISSUE_TYPE}")' in Jira project ${SCRIBE_JIRA_PROJECT} has no Description field on its create screen" >&2
    return 1
  fi
  SCRIBE_JIRA_LABELS_AVAILABLE=true
  if ! printf '%s' "${meta}" | jq -e 'any(.[]; (.fieldId // .key) == "labels")' >/dev/null; then
    SCRIBE_JIRA_LABELS_AVAILABLE=false
    echo "WARNING: issue type '$(_gha_sanitize "${SCRIBE_JIRA_ISSUE_TYPE}")' in Jira project ${SCRIBE_JIRA_PROJECT} has no Labels field on its create screen; labels will be omitted" >&2
  fi
}

# Rerun protection: print the browse URL of an issue in the configured
# project whose summary exactly matches the title (any status). Paginates
# all matches of the fuzzy JQL summary search before comparing exactly.
# Returns 1 when the lookup cannot prove absence (API failure, no searchable
# terms, or results truncated by the page cap with no exact match) so callers
# refuse to create blindly.
tracker_find_existing_issue() {
  local title="$1" raw_file jql terms match rc=0
  # JQL text search reserves most punctuation; search on the letter/digit
  # terms only (Unicode-aware) and compare the full title exactly below.
  terms=$(printf '%s' "${title}" | jq -Rr '[scan("[\\p{L}\\p{N}]+")] | join(" ")') || return 1
  if [[ -z "${terms}" ]]; then
    echo "ERROR: Jira duplicate check has no searchable terms in the issue title" >&2
    return 1
  fi
  raw_file=$(mktemp)
  jql="project = $(_scribe_jql_quote "${SCRIBE_JIRA_PROJECT}") AND summary ~ $(_scribe_jql_quote "$(_scribe_jql_quote "${terms}")")"
  _scribe_jira_search_paginated "${jql}" '["summary"]' "${raw_file}" || rc=$?
  if [[ ${rc} -ne 0 && ${rc} -ne 2 ]]; then
    rm -f "${raw_file}"
    return 1
  fi
  if ! match=$(jq -rs --arg t "${title}" '[.[][] | select(.fields.summary == $t) | .key][0] // empty' "${raw_file}"); then
    rm -f "${raw_file}"
    echo "ERROR: Jira duplicate check could not parse search results" >&2
    return 1
  fi
  rm -f "${raw_file}"
  if [[ -n "${match}" ]]; then
    echo "${JIRA_BASE_URL}/browse/${match}"
  elif [[ ${rc} -eq 2 ]]; then
    echo "ERROR: Jira duplicate check was truncated by the page cap; cannot rule out an existing issue" >&2
    return 1
  fi
}

# Create an issue in SCRIBE_JIRA_PROJECT. Body is read from stdin. Labels
# can be a JSON array or a comma-separated list; they are filtered against
# SCRIBE_JIRA_LABELS and validated before adding. Returns the issue browse URL.
#
# Delegates the actual POST to `fullsend issues create --tracker jira`,
# which handles Markdown-to-ADF conversion and the Jira REST call.
# Labels are added separately via the REST API because the CLI does not
# support a --labels flag.
forge_create_issue() {
  local _repo="$1" title="$2" labels="$3"
  local body response key url
  body=$(cat)
  if [[ -z "${FULLSEND_DIR:-}" ]]; then
    echo "ERROR: forge_create_issue: FULLSEND_DIR is not set; the fullsend CLI needs it for the tracker.jira settings" >&2
    return 1
  fi
  response=$(printf '%s' "${body}" | jira_auth_fullsend fullsend "${JIRA_TOKEN:-}" "${JIRA_USER_EMAIL:-}" \
    issues create \
    --tracker jira \
    --fullsend-dir "${FULLSEND_DIR}" \
    --project "${SCRIBE_JIRA_PROJECT}" \
    --type "${SCRIBE_JIRA_ISSUE_TYPE}" \
    --title "${title}" \
    --body -) || {
    echo "ERROR: forge_create_issue: fullsend issues create failed in project ${SCRIBE_JIRA_PROJECT}" >&2
    return 1
  }
  key=$(printf '%s' "${response}" | jq -r '.key // empty' 2>/dev/null)
  url=$(printf '%s' "${response}" | jq -r '.url // empty' 2>/dev/null)
  if [[ -z "${key}" ]] || [[ ! "${key}" =~ ^${SCRIBE_JIRA_PROJECT}-[0-9]+$ ]]; then
    echo "ERROR: forge_create_issue: fullsend issues create returned no valid issue key" >&2
    return 1
  fi
  # tracker_validate_create sets SCRIBE_JIRA_LABELS_AVAILABLE=false when the
  # create screen has no Labels field; sending it would fail every create.
  # Note: SCRIBE_JIRA_LABELS_AVAILABLE is validated against createmeta (create
  # screen). The label PUT uses the edit screen, which usually agrees with the
  # create screen for the Labels field but is not separately validated. If the
  # edit screen differs, the PUT will fail and the issue is created without
  # labels — surfaced in the step summary and Slack output below.
  local label_failed=false
  if [[ "${SCRIBE_JIRA_LABELS_AVAILABLE:-true}" == "true" ]] && [[ -n "${labels}" ]]; then
    if ! _scribe_jira_add_labels "${key}" "${labels}"; then
      echo "WARNING: forge_create_issue: failed to add labels to ${key} (issue created without labels)" >&2
      label_failed=true
    fi
  fi
  if [[ -n "${url}" ]]; then
    echo "${url}"
  else
    echo "${JIRA_BASE_URL}/browse/${key}"
  fi
  # Return 2 to signal "created successfully but labels failed" so the
  # caller (post-scribe) can surface the failure in the run summary.
  [[ "${label_failed}" == "true" ]] && return 2
  return 0
}

forge_issue_url_base() {
  echo "${JIRA_BASE_URL}/browse"
}

# Normalize and filter labels for Jira against allowlist, format, and cap.
# Returns comma-separated string for display and logging.
forge_normalize_labels() {
  local labels="$1"
  printf '%s' "$(_scribe_jira_filter_labels "${labels}")" | jq -r 'join(",")'
}
# END bundled: lib/jira-scribe-ops.lib.sh
    ;;
  *)
    echo "ERROR: invalid FULLSEND_TRACKER: '$(_gha_sanitize "${FULLSEND_TRACKER}")' — must be 'jira' or match FULLSEND_FORGE" >&2
    exit 1
    ;;
esac
# END bundled: lib/scribe-ops.lib.sh

if [[ -n "${GH_TOKEN:-}" ]]; then
  echo "::add-mask::${GH_TOKEN}"
fi
if [[ -n "${GITLAB_TOKEN:-}" ]]; then
  echo "::add-mask::${GITLAB_TOKEN}"
fi
# With FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET there is no
# token to mask here: jira-auth.lib.sh masks the access token it mints, the
# client secret is never printed, and a missing JIRA_API_URL has already
# failed the load of jira-scribe-ops.lib.sh.
if [[ -n "${JIRA_TOKEN:-}" ]]; then
  # Sanitize workflow-command delimiters before interpolating into ::add-mask::
  # so a crafted token cannot inject additional workflow commands.
  printf '::add-mask::%s\n' "$(printf '%s' "${JIRA_TOKEN}" | tr -d '\n\r')"
fi

# ============================================================
# HARD SAFETY GATE — refuse to write if dry-run is not set
# ============================================================
if [[ -z "${SCRIBE_DRY_RUN:-}" ]]; then
  echo "ERROR: SCRIBE_DRY_RUN is not set. Refusing to run."
  echo "Set SCRIBE_DRY_RUN=true for preview or SCRIBE_DRY_RUN=false for live writes."
  exit 1
fi

DRY_RUN="true"
if [[ "${SCRIBE_DRY_RUN}" == "false" ]]; then
  DRY_RUN="false"
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "::notice::DRY RUN — no repository writes will be performed"
fi

WOULD_BE=""
[[ "${DRY_RUN}" == "true" ]] && WOULD_BE="would be "

# ============================================================
# Mode: comments_only, new_issues_only, or all (default)
# ============================================================
SCRIBE_MODE="${SCRIBE_MODE:-all}"
case "${SCRIBE_MODE}" in
  all|comments_only|new_issues_only) ;;
  *)
    echo "ERROR: SCRIBE_MODE must be 'all', 'comments_only', or 'new_issues_only' (got: ${SCRIBE_MODE})"
    exit 1
    ;;
esac
# Jira: existing_issue is a numeric forge issue number, so comments on Jira
# issues are not supported yet. Only new issues are written.
if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
  if [[ "${SCRIBE_MODE}" == "comments_only" ]]; then
    echo "ERROR: SCRIBE_MODE=comments_only is not supported with FULLSEND_TRACKER=jira (comments are not supported)"
    exit 1
  fi
  if [[ "${SCRIBE_MODE}" == "all" ]]; then
    echo "::notice::FULLSEND_TRACKER=jira — comments are not supported; using new_issues_only"
    SCRIBE_MODE="new_issues_only"
  fi
fi
echo "Mode: ${SCRIBE_MODE}"

# Find the agent result JSON — prefer the validated iteration when set.
# Trust boundary: FULLSEND_VALIDATED_ITERATION_DIR is set by the fullsend CLI
# on the runner — not by the sandbox or the agent. No containment check
# (realpath / prefix guard) is applied here; the value is trusted from the
# external harness. If the trust model changes, add a realpath prefix check.
if [[ -n "${FULLSEND_VALIDATED_ITERATION_DIR:-}" ]]; then
  if [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json" ]]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json"
  elif [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/result.json" ]]; then
    # Agents sometimes write "result.json" instead of "agent-result.json";
    # validate-output-schema.sh accepts that filename as a fallback without
    # renaming it (scribe.yaml uses the default agent-result.json filename,
    # so this fallback is reachable in practice).
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/result.json"
  else
    echo "ERROR: FULLSEND_VALIDATED_ITERATION_DIR is set but contains neither agent-result.json nor result.json"
    exit 1
  fi
else
  # Backward compatibility: scan iteration-N/ subdirectories for the last
  # iteration's output (glob order = naturally ascending iteration numbers).
  RESULT_FILE=""
  for dir in iteration-*/output; do
    if [[ -f "${dir}/agent-result.json" ]]; then
      RESULT_FILE="${dir}/agent-result.json"
    fi
  done
fi

if [[ -z "${RESULT_FILE}" ]] || [[ ! -f "${RESULT_FILE}" ]]; then
  echo "ERROR: agent-result.json not found in any iteration output directory"
  exit 1
fi

echo "Reading scribe result from: ${RESULT_FILE}"

if ! jq empty "${RESULT_FILE}" 2>/dev/null; then
  echo "ERROR: ${RESULT_FILE} is not valid JSON"
  exit 1
fi

# ============================================================
# Security gate — deterministic checks on every topic
# ============================================================

MIN_CONFIDENCE="${SCRIBE_MIN_CONFIDENCE:-0.6}"
MAX_COMMENT_LEN=2000
MAX_BODY_LEN=15000
MAX_TITLE_LEN=200

is_valid_confidence() {
  [[ "${1}" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

# Numeric less-than via awk. The supported runner image does not ship bc.
numeric_lt() {
  awk -v a="${1}" -v b="${2}" 'BEGIN { exit (a+0 < b+0) ? 0 : 1 }'
}

if ! is_valid_confidence "${MIN_CONFIDENCE}"; then
  echo "ERROR: SCRIBE_MIN_CONFIDENCE must be a number between 0.0 and 1.0 (got: ${MIN_CONFIDENCE})"
  exit 1
fi
if numeric_lt "${MIN_CONFIDENCE}" "0" || numeric_lt "1" "${MIN_CONFIDENCE}"; then
  echo "ERROR: SCRIBE_MIN_CONFIDENCE must be between 0.0 and 1.0 (got: ${MIN_CONFIDENCE})"
  exit 1
fi
echo "Confidence threshold: ${MIN_CONFIDENCE}"
REJECTED=0

# The detectors feed their input via here-strings rather than `echo | grep -q`:
# with pipefail, an early-exiting reader makes the writer die of SIGPIPE on
# large inputs, the pipeline fails, and the helper wrongly reports "clean".
# Boolean sensitive-content gate for topics/new-issues (titles+bodies+labels).
# The per-span title redactor `redact_sensitive_title` in scribe-ops.lib.sh
# mirrors these secret patterns — keep the two in sync.
contains_sensitive() {
  local text="$1"
  # GitHub PATs, AWS access keys, private keys
  grep -qEi '(ghp|gho|ghs|ghr)_[A-Za-z0-9_]{36,}|\b(AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}\b|-----BEGIN.*(PRIVATE KEY)' <<< "${text}" \
    && return 0
  # Email addresses
  grep -qE '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b' <<< "${text}" \
    && return 0
  # SSN
  grep -qE '\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b' <<< "${text}" \
    && return 0
  # Slack webhooks
  grep -qE 'https://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+' <<< "${text}" \
    && return 0
  # JWTs
  grep -qE '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b' <<< "${text}" \
    && return 0
  # Generic key=value secrets
  grep -qEi '(api[_-]?key|token|secret|password|bearer)[[:space:]]*[:=][[:space:]]*['"'"'"]?[A-Za-z0-9_.~+/-]{20,}' <<< "${text}" \
    && return 0
  return 1
}

contains_suspicious_unicode() {
  local text="$1"
  # Tag characters (U+E0000–E007F), zero-width chars, BOM, bidi overrides/isolates
  perl -e 'binmode(STDIN, q(:encoding(UTF-8))); while (<STDIN>) { if (/[\x{E0000}-\x{E007F}\x{200B}\x{200C}\x{200D}\x{FEFF}\x{202A}-\x{202E}\x{2066}-\x{2069}]/) { exit 0 } } exit 1' <<< "${text}" \
    && return 0
  return 1
}

# Escape Slack mrkdwn metacharacters in link labels.
sanitize_slack_mrkdwn() {
  local val="$1"
  # Bash 5.2+ enables patsub_replacement by default, which makes a bare `&` in a
  # ${var//pat/repl} replacement expand to the matched text — turning `<` into
  # `<lt;` instead of `&lt;`. Disable it locally so the HTML entities below are
  # inserted literally (restored afterward). Matters for untrusted input such as
  # Drive document titles (issue #706) that may contain `<`, `>`, or `&`.
  local _patsub=0
  if shopt -q patsub_replacement 2>/dev/null; then
    _patsub=1
    shopt -u patsub_replacement
  fi
  # Double backslashes first: SLACK_TEXT is later expanded with `printf '%b'`, so
  # a literal `\n` in untrusted input would otherwise become a real newline (a
  # forged report line) and `\c` would truncate the message. Doubling makes the
  # backslash survive %b as a literal (issue #706).
  val="${val//\\/\\\\}"
  val="${val//&/&amp;}"
  val="${val//</&lt;}"
  val="${val//>/&gt;}"
  val="${val//|/¦}"
  [[ ${_patsub} -eq 1 ]] && shopt -s patsub_replacement
  printf '%s' "${val}"
}

# strip_unsafe_chars and redact_sensitive_title are defined in
# scribe-ops.lib.sh (sourced above) so pre-scribe can apply the same
# normalization/redaction to the document names it logs.

# Sanitize untrusted text for a Slack mrkdwn body line (e.g. Drive document
# titles, issue #706): strip unsafe chars, then escape mrkdwn metacharacters.
sanitize_slack_text() {
  sanitize_slack_mrkdwn "$(strip_unsafe_chars "$1")"
}

# Sanitize an untrusted title for display inside an inline code span in the
# GitHub step summary (e.g. Drive document titles, issue #706). The caller wraps
# the result in backticks; a code span renders its content literally, which
# suppresses Markdown links, raw HTML, AND GitHub bare-URL autolinking in one
# step, while keeping readable text like "100% sync" or "Q3 :: Planning" intact
# (so _gha_sanitize's `%`/`::` encoding is deliberately not used here).
# strip_unsafe_chars already removes backticks, so the title cannot close the
# code span.
sanitize_md_text() {
  strip_unsafe_chars "$1"
}

CONTENT_GATE_REJECTIONS=0

gate_reject() {
  local topic="$1" reason="$2"
  topic=$(_gha_sanitize "${topic}")
  reason=$(_gha_sanitize "${reason}")
  echo "  GATE REJECTED: [${topic}] — ${reason}"
  REJECTED=$((REJECTED + 1))
}

gate_reject_content() {
  local index="$1" total="$2" category="$3"
  category=$(_gha_sanitize "${category}")
  echo "  GATE REJECTED: item ${index} of ${total} — content gate: ${category}"
  REJECTED=$((REJECTED + 1))
  CONTENT_GATE_REJECTIONS=$((CONTENT_GATE_REJECTIONS + 1))
}

# ============================================================
# Dedup: merge topics referencing the same existing issue
# ============================================================
# If the LLM produces multiple entries for the same issue despite being asked
# not to, merge them: combine summaries, keep the highest confidence, keep
# public_safe=false if any entry is unsafe. Omitted entries (non-empty
# omit_reason) are never merged, so they cannot suppress or add content to
# an actionable comment.
DEDUP_FILE="${RESULT_FILE}.deduped"
jq --argjson max_len "${MAX_COMMENT_LEN}" '
  def mergeable: .existing_issue != null and ((.omit_reason // "") == "");
  .topics as $all |
  ($all | map(select(mergeable)) | group_by(.existing_issue) |
    map(
      if length == 1 then .[0]
      else
        reduce .[1:][] as $t (.[0];
          .summary = ((.summary // "") + (if (.summary // "") != "" and ($t.summary // "") != "" then "\n\n" else "" end) + ($t.summary // "")) |
          .confidence = ([.confidence, $t.confidence] | max) |
          if $t.public_safe == false then .public_safe = false | .public_safe_category = $t.public_safe_category else . end
        )
      end
      | if ((.summary // "") | length) > $max_len then
          .summary = ((.summary // "")[0:($max_len - 16)] + "\n\n_(truncated)_")
        else . end
    )
  ) as $merged |
  ($all | map(select(mergeable | not))) as $rest |
  . + {topics: ($merged + $rest)}
' "${RESULT_FILE}" > "${DEDUP_FILE}"

ORIG_COUNT=$(jq '.topics | length' "${RESULT_FILE}")
DEDUP_COUNT=$(jq '.topics | length' "${DEDUP_FILE}")
if [[ "${ORIG_COUNT}" -ne "${DEDUP_COUNT}" ]]; then
  echo "Dedup: merged ${ORIG_COUNT} → ${DEDUP_COUNT} topics ($(( ORIG_COUNT - DEDUP_COUNT )) duplicates)"
  RESULT_FILE="${DEDUP_FILE}"
else
  rm -f "${DEDUP_FILE}"
fi

# Tracking arrays for step summary (parallel indexed lists)
COMMENT_TOPICS=()
COMMENT_ISSUES=()
NEW_ISSUE_TITLES=()
NEW_ISSUE_URLS=()
SKIPPED_NEW_ISSUES=0
JIRA_DEDUP_FAILURES=0
CREATE_FAILURES=0
JIRA_LABEL_FAILURES=0
JIRA_LABEL_FAILURE_KEYS=()  # issue keys whose label PUT failed

# ============================================================
# Process comment topics (existing issues)
# ============================================================
TOPIC_COUNT=$(jq '.topics | length' "${RESULT_FILE}")

if [[ "${SCRIBE_MODE}" == "new_issues_only" ]]; then
  echo "Skipping ${TOPIC_COUNT} comment topics (mode: new_issues_only)"
  TOPIC_COUNT=0
else
  echo "Processing ${TOPIC_COUNT} topics for existing issues..."
fi

if [[ "${TOPIC_COUNT}" -gt 0 ]]; then
  for i in $(seq 0 $((TOPIC_COUNT - 1))); do
  # Read public_safe FIRST — if false, we must not log topic title or content
  PUBLIC_SAFE=$(jq -r ".topics[${i}].public_safe" "${RESULT_FILE}")
  PUBLIC_SAFE_CAT=$(jq -r ".topics[${i}].public_safe_category // empty" "${RESULT_FILE}")

  if [[ "${PUBLIC_SAFE}" == "false" ]]; then
    if [[ -z "${PUBLIC_SAFE_CAT}" || "${PUBLIC_SAFE_CAT}" == "null" ]]; then
      PUBLIC_SAFE_CAT="unspecified"
    fi
    gate_reject_content "$((i + 1))" "${TOPIC_COUNT}" "${PUBLIC_SAFE_CAT}"
    continue
  fi

  TOPIC=$(jq -r ".topics[${i}].topic" "${RESULT_FILE}")
  SUMMARY=$(jq -r ".topics[${i}].summary" "${RESULT_FILE}")
  CONFIDENCE=$(jq -r ".topics[${i}].confidence" "${RESULT_FILE}")
  ISSUE_NUM=$(jq -r ".topics[${i}].existing_issue // empty" "${RESULT_FILE}")
  OMIT=$(jq -r ".topics[${i}].omit_reason // empty" "${RESULT_FILE}")

  if [[ -n "${OMIT}" ]]; then
    if contains_sensitive "${SUMMARY}" || contains_sensitive "${TOPIC}" || contains_sensitive "${OMIT}" \
      || contains_suspicious_unicode "${SUMMARY}" || contains_suspicious_unicode "${TOPIC}" || contains_suspicious_unicode "${OMIT}"; then
      echo "  OMITTED: item $((i + 1)) of ${TOPIC_COUNT} (details suppressed)"
    else
      echo "  OMITTED: [$(_gha_sanitize "${TOPIC}")] — $(_gha_sanitize "${OMIT}")"
    fi
    continue
  fi

  if [[ -z "${ISSUE_NUM}" || "${ISSUE_NUM}" == "null" ]]; then
    continue
  fi

  # Content gates run before any gate or log line that prints the topic,
  # and reject without echoing it.
  # Gate: sensitive content (deterministic PII/secret patterns)
  if contains_sensitive "${SUMMARY}" || contains_sensitive "${TOPIC}"; then
    gate_reject_content "$((i + 1))" "${TOPIC_COUNT}" "sensitive content (PII, secrets)"
    continue
  fi

  # Gate: suspicious Unicode (prompt injection defense)
  if contains_suspicious_unicode "${SUMMARY}" || contains_suspicious_unicode "${TOPIC}"; then
    gate_reject_content "$((i + 1))" "${TOPIC_COUNT}" "suspicious Unicode (potential prompt injection)"
    continue
  fi

  if [[ ! "${ISSUE_NUM}" =~ ^[1-9][0-9]*$ ]]; then
    gate_reject "${TOPIC}" "invalid existing_issue number"
    continue
  fi

  if [[ -z "${SUMMARY}" || "${SUMMARY}" == "null" ]]; then
    gate_reject "${TOPIC}" "missing or null summary for existing issue comment"
    continue
  fi

  # Gate: confidence
  if ! is_valid_confidence "${CONFIDENCE}"; then
    gate_reject "${TOPIC}" "invalid confidence value"
    continue
  fi
  if numeric_lt "${CONFIDENCE}" "${MIN_CONFIDENCE}"; then
    gate_reject "${TOPIC}" "confidence ${CONFIDENCE} below threshold ${MIN_CONFIDENCE}"
    continue
  fi

  # Gate: length
  SUMMARY_LEN=${#SUMMARY}
  if [[ ${SUMMARY_LEN} -gt ${MAX_COMMENT_LEN} ]]; then
    gate_reject "${TOPIC}" "summary length ${SUMMARY_LEN} exceeds max ${MAX_COMMENT_LEN}"
    continue
  fi

  # Gate: code blocks in comments
  if echo "${SUMMARY}" | grep -q '```'; then
    gate_reject "${TOPIC}" "comment contains code block (unexpected in meeting summary)"
    continue
  fi

  SAFE_TOPIC=$(_gha_sanitize "${TOPIC}")
  SAFE_CONFIDENCE=$(_gha_sanitize "${CONFIDENCE}")
  echo "  PASS: [${SAFE_TOPIC}] → comment on #${ISSUE_NUM} (confidence: ${SAFE_CONFIDENCE})"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY RUN] Would post comment to ${SCRIBE_REPO}#${ISSUE_NUM}"
    COMMENT_TOPICS+=("${SAFE_TOPIC}")
    COMMENT_ISSUES+=("${ISSUE_NUM}")
  else
    # Idempotency: prefer notes URL; fall back to issue + topic + meeting date
    NOTES_URL=$(printf '%s' "${SUMMARY}" | grep -oP '\[Meeting notes\]\(\K[^)]+' || echo "")
    MEETING_DATE=$(printf '%s' "${SUMMARY}" | grep -oP '(?<=\*\*Meeting update — ).*?(?=\*\*)' || echo "")
    EXISTING=0
    COMMENTS_JSON=$(forge_list_issue_comments "${SCRIBE_REPO}" "${ISSUE_NUM}")
    if [[ -n "${NOTES_URL}" ]]; then
      EXISTING=$(echo "${COMMENTS_JSON}" \
        | jq --arg url "${NOTES_URL}" '[.[] | select(.body | contains($url))] | length' \
        2>/dev/null || echo "0")
    elif [[ -n "${MEETING_DATE}" ]]; then
      EXISTING=$(echo "${COMMENTS_JSON}" \
        | jq --arg date "${MEETING_DATE}" --arg topic "${TOPIC}" \
          '[.[] | select(.body | contains("**Meeting update — " + $date + "**") and contains($topic))] | length' \
          2>/dev/null || echo "0")
    fi
    if [[ "${EXISTING}" -gt 0 ]]; then
      echo "    SKIP: duplicate comment (already posted for this meeting/issue)"
      continue
    fi

    printf '%s' "${SUMMARY}" | forge_post_issue_comment "${SCRIBE_REPO}" "${ISSUE_NUM}"
    COMMENT_TOPICS+=("${SAFE_TOPIC}")
    COMMENT_ISSUES+=("${ISSUE_NUM}")
  fi
done
fi

# ============================================================
# Process new issues
# ============================================================
NEW_COUNT=$(jq '.new_issues | length' "${RESULT_FILE}")

if [[ "${SCRIBE_MODE}" == "comments_only" ]]; then
  echo "Skipping ${NEW_COUNT} new issue proposals (mode: comments_only)"
  SKIPPED_NEW_ISSUES=${NEW_COUNT}
  NEW_COUNT=0
else
  echo "Processing ${NEW_COUNT} new issue proposals..."
fi

# Jira: fail before any create call if the configured project/issue type
# needs required fields scribe does not set.
if [[ "${FULLSEND_TRACKER}" == "jira" ]] && [[ "${NEW_COUNT}" -gt 0 ]]; then
  if ! tracker_validate_create; then
    echo "ERROR: Jira project validation failed — no issues created"
    exit 1
  fi
fi

if [[ "${NEW_COUNT}" -gt 0 ]]; then
  for i in $(seq 0 $((NEW_COUNT - 1))); do
  # Read public_safe FIRST — if false, suppress all content from logs
  PUBLIC_SAFE=$(jq -r ".new_issues[${i}].public_safe" "${RESULT_FILE}")
  PUBLIC_SAFE_CAT=$(jq -r ".new_issues[${i}].public_safe_category // empty" "${RESULT_FILE}")

  if [[ "${PUBLIC_SAFE}" == "false" ]]; then
    if [[ -z "${PUBLIC_SAFE_CAT}" || "${PUBLIC_SAFE_CAT}" == "null" ]]; then
      PUBLIC_SAFE_CAT="unspecified"
    fi
    gate_reject_content "$((i + 1))" "${NEW_COUNT}" "${PUBLIC_SAFE_CAT}"
    continue
  fi

  TITLE=$(jq -r ".new_issues[${i}].title" "${RESULT_FILE}")
  BODY=$(jq -r ".new_issues[${i}].body" "${RESULT_FILE}")
  CONFIDENCE=$(jq -r ".new_issues[${i}].confidence" "${RESULT_FILE}")
  LABELS=$(jq -r ".new_issues[${i}].labels // [\"meeting-notes\"] | join(\",\")" "${RESULT_FILE}")

  # Content gates run before any gate that prints the title, and reject
  # without echoing it.
  # Gate: sensitive content (deterministic PII/secret patterns)
  # Labels are model-produced free text (Jira creates them on the fly), so
  # they pass the same gates as the title and body.
  if contains_sensitive "${TITLE}" || contains_sensitive "${BODY}" || contains_sensitive "${LABELS}"; then
    gate_reject_content "$((i + 1))" "${NEW_COUNT}" "sensitive content"
    continue
  fi

  # Gate: suspicious Unicode (prompt injection defense)
  if contains_suspicious_unicode "${TITLE}" || contains_suspicious_unicode "${BODY}" || contains_suspicious_unicode "${LABELS}"; then
    gate_reject_content "$((i + 1))" "${NEW_COUNT}" "suspicious Unicode (potential prompt injection)"
    continue
  fi

  # Gate: confidence
  if ! is_valid_confidence "${CONFIDENCE}"; then
    gate_reject "${TITLE}" "invalid confidence value"
    continue
  fi
  if numeric_lt "${CONFIDENCE}" "${MIN_CONFIDENCE}"; then
    gate_reject "${TITLE}" "confidence ${CONFIDENCE} below threshold ${MIN_CONFIDENCE}"
    continue
  fi

  # Gate: lengths
  TITLE_LEN=${#TITLE}
  BODY_LEN=${#BODY}
  if [[ ${TITLE_LEN} -gt ${MAX_TITLE_LEN} ]]; then
    gate_reject "${TITLE}" "title length ${TITLE_LEN} exceeds max ${MAX_TITLE_LEN}"
    continue
  fi
  if [[ ${BODY_LEN} -gt ${MAX_BODY_LEN} ]]; then
    gate_reject "${TITLE}" "body length ${BODY_LEN} exceeds max ${MAX_BODY_LEN}"
    continue
  fi

  # Gate: code blocks in issue bodies
  if echo "${BODY}" | grep -q '```'; then
    gate_reject "${TITLE}" "issue body contains code block (unexpected in meeting summary)"
    continue
  fi

  SAFE_TITLE=$(_gha_sanitize "${TITLE}")
  SAFE_CONFIDENCE=$(_gha_sanitize "${CONFIDENCE}")
  echo "  PASS: [${SAFE_TITLE}] → new issue (confidence: ${SAFE_CONFIDENCE})"
  NEW_ISSUE_TITLES+=("${SAFE_TITLE}")

  # Prepend auto-generated banner so reviewers know this was machine-created
  BANNER='> [!NOTE]
> This issue was automatically generated from meeting notes by the scribe agent.
> Please review, edit, and add any missing context before prioritizing.

'
  FULL_BODY="${BANNER}${BODY}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY RUN] Would create issue: ${SAFE_TITLE}"
    DISPLAY_LABELS=$(forge_normalize_labels "${LABELS}")
    echo "    [DRY RUN] Labels: $(_gha_sanitize "${DISPLAY_LABELS}")"
    echo "    [DRY RUN] Body length: ${BODY_LEN} chars"
    NEW_ISSUE_URLS+=("")
  else
    # Jira rerun protection: skip if an issue with the same summary exists.
    if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
      if ! EXISTING_URL=$(tracker_find_existing_issue "${TITLE}"); then
        echo "  ERROR: Jira duplicate check failed — refusing to create issue: ${SAFE_TITLE}"
        JIRA_DEDUP_FAILURES=$((JIRA_DEDUP_FAILURES + 1))
        unset "NEW_ISSUE_TITLES[$((${#NEW_ISSUE_TITLES[@]} - 1))]"
        continue
      fi
      if [[ -n "${EXISTING_URL}" ]]; then
        echo "    SKIP: duplicate issue (already exists: ${EXISTING_URL})"
        unset "NEW_ISSUE_TITLES[$((${#NEW_ISSUE_TITLES[@]} - 1))]"
        continue
      fi
    fi
    CREATE_RC=0
    ISSUE_URL=$(printf '%s' "${FULL_BODY}" | forge_create_issue "${SCRIBE_REPO}" "${TITLE}" "${LABELS}") || CREATE_RC=$?
    if [[ ${CREATE_RC} -ne 0 && ${CREATE_RC} -ne 2 ]]; then
      echo "    ERROR: forge_create_issue failed (exit ${CREATE_RC})"
      unset "NEW_ISSUE_TITLES[$((${#NEW_ISSUE_TITLES[@]} - 1))]"
      CREATE_FAILURES=$((CREATE_FAILURES + 1))
      continue
    fi
    echo "    Created: ${ISSUE_URL}"
    NEW_ISSUE_URLS+=("${ISSUE_URL}")
    # Exit code 2 means the issue was created but the label PUT failed.
    if [[ ${CREATE_RC} -eq 2 ]]; then
      JIRA_LABEL_FAILURES=$((JIRA_LABEL_FAILURES + 1))
      # Extract issue key from URL (e.g. PROJ-100 from .../browse/PROJ-100)
      JIRA_LABEL_FAILURE_KEYS+=("${ISSUE_URL##*/}")
    fi
  fi
done
fi

# ============================================================
# Summary (console)
# ============================================================
RUN_MODE_LABEL="LIVE"
[[ "${DRY_RUN}" == "true" ]] && RUN_MODE_LABEL="DRY RUN"

# No-notes detection (issue #1618). pre-scribe writes a runner-side
# scribe-meta.json whose docs_downloaded holds the search's matching-document
# count (a confirmed numeric 0 is the successful empty search).
#
# The empty-search *signal* comes from the metadata; the concise *message*
# additionally requires the agent to have produced nothing at the source — zero
# topics and zero new-issue proposals, read straight from RESULT_FILE rather than
# TOPIC_COUNT / NEW_COUNT (which mode handling zeroes: new_issues_only zeroes
# TOPIC_COUNT, comments_only zeroes NEW_COUNT). Gating on the raw result covers
# every "something happened" case at once — comments posted, issues created,
# issues skipped by mode (SKIPPED_NEW_ISSUES), gate rejections (REJECTED), and
# create/dedup failures (CREATE_FAILURES / JIRA_DEDUP_FAILURES) only arise when
# there were topics or proposals to begin with — so a zero-document search that
# still returned proposals keeps the activity report. A run that found notes but
# extracted zero topics has docs_downloaded > 0 and keeps the normal report.
SCRIBE_META_FILE="${RUNNER_TEMP:-/tmp}/scribe-workspace/scribe-meta.json"
NO_NOTES=false
# NO_NOTES_DOCS records why the no-notes branch did/did not fire so a silent
# fallback is diagnosable from the job log (printed in the summary below):
# "missing" (no meta), "invalid" (unparseable JSON or a non-object root), or the
# numeric docs_downloaded value. The guard requires an object root: valid JSON
# with a non-object root ([], "x", 123, true) passes a bare `jq -e .` but then
# errors on `.docs_downloaded` (jq exit 5), which under `set -e` would abort the
# run before the summary and Slack delivery.
if [[ ! -f "${SCRIBE_META_FILE}" ]]; then
  NO_NOTES_DOCS="missing"
elif ! jq -e 'type == "object"' "${SCRIBE_META_FILE}" >/dev/null 2>&1; then
  NO_NOTES_DOCS="invalid"
else
  NO_NOTES_DOCS="$(jq -r '(.docs_downloaded | numbers) // "nan"' "${SCRIBE_META_FILE}")"
  if [[ "${NO_NOTES_DOCS}" == "0" ]]; then
    RESULT_TOPIC_TOTAL=$(jq '.topics | length' "${RESULT_FILE}")
    RESULT_NEW_ISSUE_TOTAL=$(jq '.new_issues | length' "${RESULT_FILE}")
    if [[ "${RESULT_TOPIC_TOTAL}" -eq 0 && "${RESULT_NEW_ISSUE_TOTAL}" -eq 0 ]]; then
      NO_NOTES=true
    fi
  fi
fi

# Meeting titles (issue #706) come from a runner-only scribe-titles.json that is
# NOT mounted into the sandbox, so untrusted Drive titles never enter the agent
# context. Normalize each title with strip_unsafe_chars FIRST, then redact
# sensitive spans on the normalized text — so the redactor sees exactly what will
# be published (a zero-width char cannot split a secret/email past it and then be
# stripped at display). redact_sensitive_title replaces only the matching span,
# so a non-sensitive remainder keeps the meeting identifiable. Read NUL-delimited
# so a title containing a newline stays one element.
SCRIBE_TITLES_FILE="${RUNNER_TEMP:-/tmp}/scribe-workspace/scribe-titles.json"
MEETING_TITLES=()
if [[ -f "${SCRIBE_TITLES_FILE}" ]] && jq -e 'type == "object"' "${SCRIBE_TITLES_FILE}" >/dev/null 2>&1; then
  while IFS= read -r -d '' _title; do
    _title=$(strip_unsafe_chars "${_title}")
    # Explicit if (not `[[ … ]] && …`) so skipping an empty title keeps a success
    # status and cannot trip `set -e` on the loop body.
    if [[ -n "${_title}" ]]; then
      MEETING_TITLES+=("$(redact_sensitive_title "${_title}")")
    fi
  done < <(jq -j '(.doc_names // [])[] | . + "\u0000"' "${SCRIBE_TITLES_FILE}")
fi

echo ""
echo "=== Scribe Post-Script Summary ==="
echo "  Run mode: ${RUN_MODE_LABEL}"
echo "  Agent mode: ${SCRIBE_MODE}"
echo "  No-notes check: docs_downloaded=${NO_NOTES_DOCS} -> NO_NOTES=${NO_NOTES}"
echo "  Topics processed: ${TOPIC_COUNT}"
echo "  Comments ${WOULD_BE}posted: ${#COMMENT_TOPICS[@]}"
echo "  New issues ${WOULD_BE}created: ${#NEW_ISSUE_TITLES[@]}"
echo "  Gate rejections: ${REJECTED}"
echo "    Content gate: ${CONTENT_GATE_REJECTIONS}"
echo "  New proposals reviewed: ${NEW_COUNT}"
[[ "${SKIPPED_NEW_ISSUES}" -gt 0 ]] && echo "  Skipped new issues (mode): ${SKIPPED_NEW_ISSUES}"
if [[ "${JIRA_LABEL_FAILURES}" -gt 0 ]]; then
  echo "  Label failures: ${JIRA_LABEL_FAILURES} issue(s) created without labels: ${JIRA_LABEL_FAILURE_KEYS[*]}"
fi
echo "=================================="

# ============================================================
# Step summary — markdown report for CI job page
# ============================================================
ISSUE_BASE=$(forge_issue_url_base "${SCRIBE_REPO}")
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
{
  echo "### Scribe agent report (${RUN_MODE_LABEL})"
  echo ""
  if [[ ${#MEETING_TITLES[@]} -eq 1 ]]; then
    echo "**Meeting:** \`$(sanitize_md_text "${MEETING_TITLES[0]}")\`"
    echo ""
  elif [[ ${#MEETING_TITLES[@]} -gt 1 ]]; then
    echo "**Meetings (${#MEETING_TITLES[@]}):**"
    for _title in "${MEETING_TITLES[@]}"; do
      echo "- \`$(sanitize_md_text "${_title}")\`"
    done
    echo ""
  fi
  echo "| Metric | Count |"
  echo "|--------|------:|"
  echo "| Topics processed | ${TOPIC_COUNT} |"
  echo "| Comments ${WOULD_BE}posted | ${#COMMENT_TOPICS[@]} |"
  echo "| New issues ${WOULD_BE}created | ${#NEW_ISSUE_TITLES[@]} |"
  echo "| Gate rejections | ${REJECTED} |"
  echo "| Content gate rejections | ${CONTENT_GATE_REJECTIONS} |"
  if [[ "${SKIPPED_NEW_ISSUES}" -gt 0 ]]; then
    echo "| Skipped (${SCRIBE_MODE}) | ${SKIPPED_NEW_ISSUES} |"
  fi
  echo ""

  if [[ ${#COMMENT_TOPICS[@]} -gt 0 ]]; then
    echo "**Comments ${WOULD_BE}posted:** ${#COMMENT_TOPICS[@]}"
    for idx in "${!COMMENT_TOPICS[@]}"; do
      echo "- [#${COMMENT_ISSUES[$idx]} — ${COMMENT_TOPICS[$idx]}](${ISSUE_BASE}/${COMMENT_ISSUES[$idx]})"
    done
    echo ""
  fi

  if [[ ${#NEW_ISSUE_TITLES[@]} -gt 0 ]]; then
    echo "**New issues ${WOULD_BE}filed:** ${#NEW_ISSUE_TITLES[@]}"
    for idx in "${!NEW_ISSUE_TITLES[@]}"; do
      if [[ -n "${NEW_ISSUE_URLS[$idx]:-}" ]]; then
        echo "- [${NEW_ISSUE_TITLES[$idx]}](${NEW_ISSUE_URLS[$idx]})"
      else
        echo "- ${NEW_ISSUE_TITLES[$idx]}"
      fi
    done
    echo ""
  fi

  if [[ "${JIRA_LABEL_FAILURES}" -gt 0 ]]; then
    echo "> :warning: **${JIRA_LABEL_FAILURES}** issue(s) created without labels (label PUT failed): ${JIRA_LABEL_FAILURE_KEYS[*]}"
    echo ""
  fi

  if [[ "${REJECTED}" -gt 0 ]]; then
    echo "> **${REJECTED}** topic(s) rejected by the security gate."
    if [[ "${CONTENT_GATE_REJECTIONS}" -gt 0 ]]; then
      echo "> ${CONTENT_GATE_REJECTIONS} rejected by content gate (details suppressed for safety)."
    fi
    echo ""
  fi

  echo "_Confidence threshold: ${MIN_CONFIDENCE} · Mode: ${SCRIBE_MODE}_"
} >> "${GITHUB_STEP_SUMMARY}"
  echo "Step summary written to GITHUB_STEP_SUMMARY"
fi

# ============================================================
# Slack notification (optional — skip silently if no webhook)
# ============================================================
SLACK_WEBHOOK="${SCRIBE_SLACK_WEBHOOK_URL:-${SLACK_WEBHOOK_URL:-}}"
if [[ -n "${SLACK_WEBHOOK}" ]]; then
  echo "::add-mask::${SLACK_WEBHOOK}"
  RUN_URL=$(forge_run_url "${SCRIBE_REPO}")

  SLACK_TEXT=":memo: *Scribe agent* (${RUN_MODE_LABEL})"
  if [[ ${#MEETING_TITLES[@]} -eq 1 ]]; then
    # Render in a code span (backtick-wrapped), like the step summary: per
    # Slack's formatting reference, text in inline code is not reformatted
    # with other mrkdwn syntax, so an untrusted title cannot inject emphasis
    # (*bold*, _italic_, ~strike~) into the notification. Slack's docs do not
    # explicitly state whether a bare URL is still auto-linked/clickable
    # inside a code span, so this is not relied on alone: unfurl_links/
    # unfurl_media are disabled on the payload below, independently closing
    # the link-preview risk regardless of code-span semantics.
    # strip_unsafe_chars already removed any backtick from the title, so it
    # cannot close the span early. The entity escaping above (&, <, >) is kept
    # as defense-in-depth against Slack's own link/mention syntax, even though
    # whether it is still decoded inside a code span is similarly unverified.
    SLACK_TEXT+="\nMeeting: \`$(sanitize_slack_text "${MEETING_TITLES[0]}")\`"
  elif [[ ${#MEETING_TITLES[@]} -gt 1 ]]; then
    SLACK_TEXT+="\nMeetings (${#MEETING_TITLES[@]}):"
    for _title in "${MEETING_TITLES[@]}"; do
      SLACK_TEXT+="\n  • \`$(sanitize_slack_text "${_title}")\`"
    done
  fi
  if [[ "${NO_NOTES}" == "true" ]]; then
    SLACK_TEXT+="\nNo meeting notes found for today."
  else
    SLACK_TEXT+="\nMode: \`${SCRIBE_MODE}\` · Confidence: \`${MIN_CONFIDENCE}\`"
    SLACK_TEXT+="\n• Topics processed: *${TOPIC_COUNT}*"
    SLACK_TEXT+="\n• Comments: *${#COMMENT_TOPICS[@]}*"
    SLACK_TEXT+="\n• New issues: *${#NEW_ISSUE_TITLES[@]}*"
    SLACK_TEXT+="\n• Gate rejections: *${REJECTED}*"
    if [[ "${CONTENT_GATE_REJECTIONS}" -gt 0 ]]; then
      SLACK_TEXT+=" (${CONTENT_GATE_REJECTIONS} content)"
    fi
    if [[ "${SKIPPED_NEW_ISSUES}" -gt 0 ]]; then
      SLACK_TEXT+="\n• Skipped (${SCRIBE_MODE}): *${SKIPPED_NEW_ISSUES}*"
    fi
    if [[ "${JIRA_LABEL_FAILURES}" -gt 0 ]]; then
      SLACK_TEXT+="\n• :warning: Label failures: *${JIRA_LABEL_FAILURES}* (${JIRA_LABEL_FAILURE_KEYS[*]})"
    fi

    if [[ ${#COMMENT_TOPICS[@]} -gt 0 ]]; then
      SLACK_TEXT+="\n\n*Comments:*"
      for idx in "${!COMMENT_TOPICS[@]}"; do
        SLACK_TOPIC=$(sanitize_slack_mrkdwn "${COMMENT_TOPICS[$idx]}")
        SLACK_TEXT+="\n  • <${ISSUE_BASE}/${COMMENT_ISSUES[$idx]}|#${COMMENT_ISSUES[$idx]} — ${SLACK_TOPIC}>"
      done
    fi

    if [[ ${#NEW_ISSUE_TITLES[@]} -gt 0 ]]; then
      SLACK_TEXT+="\n\n*New issues:*"
      for idx in "${!NEW_ISSUE_TITLES[@]}"; do
        SLACK_TITLE=$(sanitize_slack_mrkdwn "${NEW_ISSUE_TITLES[$idx]}")
        if [[ -n "${NEW_ISSUE_URLS[$idx]:-}" ]]; then
          SLACK_TEXT+="\n  • <${NEW_ISSUE_URLS[$idx]}|${SLACK_TITLE}>"
        else
          SLACK_TEXT+="\n  • ${SLACK_TITLE}"
        fi
      done
    fi
  fi

  SLACK_TEXT+="\n\n<${RUN_URL}|View run>"

  # unfurl_links/unfurl_media: false — independent of whether Slack's code-span
  # rendering suppresses auto-linking, this unconditionally stops Slack from
  # generating a link-preview card for a URL in an untrusted meeting title
  # (issue #706). No other URL in this message needs an unfurl.
  SLACK_PAYLOAD=$(printf '%b' "${SLACK_TEXT}" | jq -Rs '{text: ., unfurl_links: false, unfurl_media: false}')
  # Slack is best-effort: bound the request so a stalled webhook cannot hang the job.
  if printf '%s' "${SLACK_PAYLOAD}" \
      | curl -fsSL --connect-timeout 10 --max-time 30 \
        -X POST -H 'Content-Type: application/json' \
        --data-binary @- "${SLACK_WEBHOOK}" >/dev/null 2>&1; then
    echo "Slack notification sent"
  else
    echo "WARNING: Slack notification failed (non-fatal)"
  fi
  unset SLACK_WEBHOOK
else
  echo "No SCRIBE_SLACK_WEBHOOK_URL set — skipping Slack notification"
fi

# Deferred failure: if any Jira duplicate checks or issue creates failed, exit
# non-zero after finalization so already-created issues are reported in the summary.
if [[ "${JIRA_DEDUP_FAILURES}" -gt 0 || "${CREATE_FAILURES}" -gt 0 ]]; then
  echo "ERROR: ${JIRA_DEDUP_FAILURES} Jira duplicate check(s) and/or ${CREATE_FAILURES} issue creation(s) failed — exiting with error"
  exit 1
fi
