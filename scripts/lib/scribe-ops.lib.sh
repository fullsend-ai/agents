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
