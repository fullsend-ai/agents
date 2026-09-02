#!/usr/bin/env bash
# filter-review-diff.sh — Strip unreviewable bytes from a unified diff before
# any review model reads them.
#
# No model can meaningfully assess a lockfile hunk, minified/sourcemap
# output, or vendored code — on a mixed PR they are pure input cost for
# every review dimension. This filters them out deterministically, before
# context assembly, so both the small-PR (full diff) and large-PR (per-file
# diff) paths in SKILL.md step 2 share one definition of "generated".
#
# Usage:
#   filter-review-diff.sh [summary-file] < unified-diff > filtered-diff
#
#   $1 (optional) — path to write the exclusion summary to. One line per
#                   stripped file: "<path>  +<adds>/-<dels>  <reason>".
#                   Defaults to /dev/null (summary discarded). The summary
#                   is NEVER written to stdout — callers that need it must
#                   pass a real file.
#
# Classification (per `diff --git a/X b/X` section), in priority order:
#   1. EXEMPT (always kept, beats every rule below): path has a
#      "migrations" or "migrate" directory component.
#   2. STRIP: path matches the dependency-lockfile list (mirrors the
#      is_lock() regex in fullsend's .github/scripts/route-review-model.sh
#      — cross-repo duplicate, kept in sync by hand), or is `*.min.js` /
#      `*.min.css` / `*.map`, or sits under a `vendor/`, `node_modules/`,
#      or `third_party/` path segment.
#   3. STRIP: `@generated` appears in one of the section's first 5 ADDED
#      lines (removed-line-only mentions do not strip — the file is
#      leaving, not arriving, generated).
#   4. Otherwise: kept, byte-identical.
#
# Bash 3.2 compatible (macOS ships 3.2 — no associative arrays, no
# ${var,,}). The classifier itself is a single awk program reading stdin
# one line at a time: a multi-thousand-line lockfile hunk is never
# buffered whole, in awk or in a shell variable. The only lines ever held
# in memory are one file-section's header lines, plus (for sections that
# are not fast-path classified by path) content lines up to the 5-added-
# line @generated check — capped at 100 buffered lines per section, so a
# deletion-only section never buffers whole.
#
# Malformed input (no `diff --git` markers, or a section this parser
# can't make sense of) passes through unchanged rather than erroring:
# the failure mode here must be an unfiltered review, never a broken one.
set -euo pipefail

SUMMARY_FILE="${1:-/dev/null}"

# Truncate up front: a no-exclusions run must leave an empty summary, not
# a previous run's stale one. Harmless no-op on /dev/null.
: > "${SUMMARY_FILE}"

awk -v summary_file="${SUMMARY_FILE}" '
function reset_section() {
  path = ""; old_path = ""; new_path = ""
  hdr_old = ""; hdr_new = ""
  phase = "header"      # header -> pending -> keep|strip
  reason = ""
  added_seen = 0
  generated_hit = 0
  sec_adds = 0
  sec_dels = 0
  buf_n = 0
}

# Index of the closing quote of the git-quoted string starting at
# position 1 of s, or 0 if unterminated.
function quote_end(s,   i, c) {
  for (i = 2; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\") i++
    else if (c == "\"") return i
  }
  return 0
}

# Undoes git path quoting: strips the surrounding double quotes and the
# common escapes (\" \\ \t \n). Other escapes (octal bytes) are left
# as-is — classification only pattern-matches path shape.
function dequote(s,   out, i, c) {
  s = substr(s, 2, length(s) - 2)
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\" && i < length(s)) {
      c = substr(s, i + 1, 1)
      if (c == "t") { out = out "\t"; i++; continue }
      if (c == "n") { out = out "\n"; i++; continue }
      if (c == "\"" || c == "\\") { out = out c; i++; continue }
      c = "\\"
    }
    out = out c
  }
  return out
}

# Position of the last occurrence of t in s, or 0.
function last_index(s, t,   i, p) {
  p = 0
  for (i = index(s, t); i > 0; i = index(substr(s, p + 1), t)) p += i
  return p
}

# Best-effort old/new paths from the `diff --git a/X b/Y` header line
# itself — the only header a binary or mode-only section is guaranteed
# to carry, and the fallback when the ---/+++ paths are git-quoted.
# Leaves hdr_old/hdr_new empty when the line cannot be split (an
# unparsed section fails open at classification time).
function parse_git_header(line,   rest, i, cut) {
  rest = substr(line, 12)
  if (substr(rest, 1, 1) == "\"") {
    i = quote_end(rest)
    if (i == 0 || substr(rest, i + 1, 1) != " ") return
    if (substr(rest, 2, 2) == "a/") hdr_old = substr(dequote(substr(rest, 1, i)), 3)
    rest = substr(rest, i + 2)
  } else {
    # An unquoted a-path may itself contain spaces: the b-path starts
    # at the last " b/" (or quoted: " \"b/) marker on the line.
    cut = last_index(rest, " b/")
    i = last_index(rest, " \"b/")
    if (i > cut) cut = i
    if (cut == 0) return
    if (substr(rest, 1, 2) == "a/") hdr_old = substr(rest, 3, cut - 3)
    rest = substr(rest, cut + 1)
  }
  if (substr(rest, 1, 1) == "\"") {
    i = quote_end(rest)
    if (i == 0) return
    rest = dequote(substr(rest, 1, i))
  }
  if (substr(rest, 1, 2) == "b/") hdr_new = substr(rest, 3)
}

# The path a section is classified by: ---/+++ (or rename) headers
# first, the diff --git header as fallback. Empty means unparseable.
function section_path() {
  if (new_path != "") return new_path
  if (old_path != "") return old_path
  if (hdr_new != "") return hdr_new
  return hdr_old
}

# Classifies the current `path` into phase=keep|strip(+reason)|pending.
# pending means: not exempt, not a fast-path strip — still need the
# first-5-added-lines @generated check before a final call can be made.
function classify_path(   lp) {
  if (path ~ /(^|\/)(migrations|migrate)\//) {
    phase = "keep"
    return
  }
  lp = tolower(path)
  # Lockfile list mirrors is_lock() in fullsends
  # .github/scripts/route-review-model.sh (lines 65-84 there).
  if (lp ~ /(^|\/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|npm-shrinkwrap\.json|go\.sum|cargo\.lock|gemfile\.lock|poetry\.lock|composer\.lock)$/) {
    phase = "strip"; reason = "lockfile"; return
  }
  if (path ~ /\.min\.(js|css)$/) {
    phase = "strip"; reason = "minified"; return
  }
  if (path ~ /\.map$/) {
    phase = "strip"; reason = "sourcemap"; return
  }
  if (path ~ /(^|\/)(vendor|node_modules|third_party)\//) {
    phase = "strip"; reason = "vendored"; return
  }
  phase = "pending"
}

function flush_buf(   i) {
  for (i = 1; i <= buf_n; i++) print buf[i]
  buf_n = 0
}

# Emits the one-line exclusion-summary record for the section that just
# finished being classified "strip". Never touches stdout.
function emit_summary() {
  print path "  +" sec_adds "/-" sec_dels "  " reason > summary_file
}

# Called when a section closes (next "diff --git" line, or EOF) to settle
# any decision that was left open while streaming.
function finalize_section() {
  if (phase == "strip") {
    emit_summary()
  } else if (phase == "pending") {
    # Section ended before 5 added lines ever appeared (small change, or a
    # deletion-heavy diff) - decide from whatever the first <5 held.
    if (generated_hit) { reason = "generated-marker"; emit_summary() }
    else { flush_buf() }
  } else if (phase == "header") {
    # No hunk and no "Binary files" line ever appeared: a pure rename or
    # mode-only change with no content diff at all. Classify from
    # whichever path we captured.
    path = section_path()
    if (path == "") { flush_buf(); return }
    classify_path()
    if (phase == "strip") { buf_n = 0; emit_summary() }
    else { flush_buf() }
  }
  # phase == "keep": already streamed directly, buffer is already empty.
}

BEGIN { in_diff = 0; reset_section() }

{
  line = $0

  if (!in_diff) {
    if (line ~ /^diff --git /) {
      in_diff = 1
      buf[++buf_n] = line
      parse_git_header(line)
    } else {
      print line
    }
    next
  }

  if (line ~ /^diff --git /) {
    finalize_section()
    reset_section()
    buf[++buf_n] = line
    parse_git_header(line)
    next
  }

  if (phase == "keep") {
    print line
    next
  }

  if (phase == "strip") {
    c = substr(line, 1, 1)
    if (c == "+") sec_adds++
    else if (c == "-") sec_dels++
    next
  }

  if (phase == "header") {
    if (line ~ /^--- /) {
      p = substr(line, 5)
      if (p != "/dev/null" && substr(p, 1, 2) == "a/") old_path = substr(p, 3)
      buf[++buf_n] = line
      next
    }
    if (line ~ /^\+\+\+ /) {
      p = substr(line, 5)
      if (p != "/dev/null" && substr(p, 1, 2) == "b/") new_path = substr(p, 3)
      buf[++buf_n] = line
      next
    }
    if (line ~ /^rename to /) {
      if (new_path == "") new_path = substr(line, 11)
      buf[++buf_n] = line
      next
    }
    if (line ~ /^rename from /) {
      if (old_path == "") old_path = substr(line, 13)
      buf[++buf_n] = line
      next
    }
    if (line ~ /^@@ / || line ~ /^Binary files /) {
      buf[++buf_n] = line
      path = section_path()
      if (path == "") {
        # Fail-open: no path parsed from any header — never classify
        # (much less strip) a section this parser cannot even name.
        phase = "keep"; flush_buf(); next
      }
      classify_path()
      if (phase == "keep") { flush_buf(); next }
      if (phase == "strip") { buf_n = 0; next }
      next   # phase == "pending": keep buffering into the content below
    }
    buf[++buf_n] = line
    next
  }

  # phase == "pending": buffering, watching the first 5 added lines only.
  # The decision resolves at the 5th added line or the 100th buffered
  # line, whichever comes first, so a deletion-only or low-addition
  # section never buffers unbounded.
  buf[++buf_n] = line
  c = substr(line, 1, 1)
  if (c == "+") {
    sec_adds++
    if (added_seen < 5) {
      added_seen++
      if (index(line, "@generated") > 0) generated_hit = 1
    }
  } else if (c == "-") {
    sec_dels++
  }
  if (added_seen >= 5 || buf_n >= 100) {
    if (generated_hit) { reason = "generated-marker"; phase = "strip"; buf_n = 0 }
    else { phase = "keep"; flush_buf() }
  }
  next
}

END { if (in_diff) finalize_section() }
'
