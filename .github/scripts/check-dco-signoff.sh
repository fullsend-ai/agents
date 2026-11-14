#!/usr/bin/env bash
# check-dco-signoff.sh — Validate DCO sign-off in commit messages.
#
# Ensures that commit messages contain a Signed-off-by trailer matching
# the git author or committer identity for human commits.
# Skips merge commits and [bot] authors.

set -euo pipefail

COMMIT_MSG_FILE="${1:-}"

if [[ -z "${COMMIT_MSG_FILE}" ]]; then
  echo "Error: Commit message file argument missing." >&2
  echo "Usage: $0 <commit-msg-file>" >&2
  exit 1
fi

if [[ ! -f "${COMMIT_MSG_FILE}" ]]; then
  echo "Error: Commit message file '${COMMIT_MSG_FILE}' not found." >&2
  exit 1
fi

# Skip merge commits only when Git indicates an active merge in progress
merge_head="$(git rev-parse --git-path MERGE_HEAD 2>/dev/null || true)"
if [[ -n "${merge_head}" && -f "${merge_head}" ]]; then
  exit 0
fi

# Extract author identity from git
if ! author_ident="$(git var GIT_AUTHOR_IDENT 2>/dev/null)"; then
  echo "Error: Unable to determine git author identity from 'git var GIT_AUTHOR_IDENT'." >&2
  echo "Ensure 'user.name' and 'user.email' are configured in git." >&2
  exit 1
fi

# Extract committer identity from git
if ! committer_ident="$(git var GIT_COMMITTER_IDENT 2>/dev/null)"; then
  echo "Error: Unable to determine git committer identity from 'git var GIT_COMMITTER_IDENT'." >&2
  echo "Ensure 'user.name' and 'user.email' are configured in git." >&2
  exit 1
fi

# Ident format: "Name <email> timestamp tz"
author_name="$(echo "${author_ident}" | sed -E 's/^(.*) <[^>]+>.*/\1/')"
author_email="$(echo "${author_ident}" | sed -E 's/^.* <([^>]+)>.*/\1/')"
if [[ -z "${author_name}" || -z "${author_email}" || "${author_email}" == "${author_ident}" ]]; then
  echo "Error: Failed to parse author name and email from git author ident: ${author_ident}" >&2
  exit 1
fi

committer_name="$(echo "${committer_ident}" | sed -E 's/^(.*) <[^>]+>.*/\1/')"
committer_email="$(echo "${committer_ident}" | sed -E 's/^.* <([^>]+)>.*/\1/')"
if [[ -z "${committer_name}" || -z "${committer_email}" || "${committer_email}" == "${committer_ident}" ]]; then
  echo "Error: Failed to parse committer name and email from git committer ident: ${committer_ident}" >&2
  exit 1
fi

# Skip [bot] git authors:
# Match if the author name has [bot] (e.g. dependabot[bot], github-actions[bot])
# or if the author email is a GitHub bot noreply email (*[bot]@users.noreply.github.com),
# matching Probot dco.js (author.type === "Bot").
is_bot() {
  local name="$1"
  local email="$2"
  [[ "${name}" =~ \[[bB][oO][tT]\] ]] || [[ "${email}" =~ \[[bB][oO][tT]\]@users\.noreply\.github\.com$ ]]
}

if is_bot "${author_name}" "${author_email}"; then
  exit 0
fi

author="${author_name} <${author_email}>"
committer="${committer_name} <${committer_email}>"

# Determine comment character (respects core.commentChar, defaults to '#')
comment_char="$(git config --get core.commentChar 2>/dev/null || true)"
if [[ -z "${comment_char}" || "${comment_char}" == "auto" ]]; then
  comment_char="#"
fi

# Validate commit message content before the scissors cutoff line,
# ignoring comment lines and CRLF line endings.
# Uses a single awk process reading the file directly to avoid pipeline SIGPIPE issues.
# Matches Probot dco.js behavior: accepts a Signed-off-by trailer whose name is in
# {author_name, committer_name} and whose email is in {author_email, committer_email}
# (case-insensitive for name, email and Signed-off-by prefix, tolerating trailing whitespace).
# Author and committer idents are passed via environment variables so awk ENVIRON
# reads them verbatim without interpreting backslash escapes (unlike awk -v).
if ! AUTHOR_NAME="${author_name}" \
     AUTHOR_EMAIL="${author_email}" \
     COMMITTER_NAME="${committer_name}" \
     COMMITTER_EMAIL="${committer_email}" \
     COMMENT_CHAR="${comment_char}" \
     awk '
  BEGIN {
    author_name = tolower(ENVIRON["AUTHOR_NAME"])
    author_email = tolower(ENVIRON["AUTHOR_EMAIL"])
    committer_name = tolower(ENVIRON["COMMITTER_NAME"])
    committer_email = tolower(ENVIRON["COMMITTER_EMAIL"])
    cchar = ENVIRON["COMMENT_CHAR"]
    found = 0
  }
  {
    sub(/\r$/, "")
    sub(/[ \t]+$/, "")

    # Only lines starting with comment_char at column 1 are comments
    if (length($0) >= length(cchar) && substr($0, 1, length(cchar)) == cchar) {
      # Git scissors line: commentChar + " ------------------------ >8 ------------------------"
      if ($0 == cchar " ------------------------ >8 ------------------------") {
        exit
      }
      next
    }

    # Probot dco.js format: /^Signed-off-by: (.*) <(.*)>\s*$/i
    # Requires column-1 "Signed-off-by: " with exact single space after colon
    if (tolower(substr($0, 1, 15)) == "signed-off-by: ") {
      rest = substr($0, 16)
      if (substr(rest, length(rest)) == ">") {
        idx = 0
        for (i = length(rest) - 1; i >= 1; i--) {
          if (substr(rest, i, 1) == "<") {
            idx = i
            break
          }
        }
        # Require space before "<", non-empty name, non-empty email, no ">" inside email
        if (idx > 2 && substr(rest, idx - 1, 1) == " ") {
          line_name = substr(rest, 1, idx - 2)
          line_email = substr(rest, idx + 1, length(rest) - idx - 1)
          if (length(line_name) > 0 && length(line_email) > 0 && index(line_email, ">") == 0) {
            name_match = (tolower(line_name) == author_name || tolower(line_name) == committer_name)
            email_match = (tolower(line_email) == author_email || tolower(line_email) == committer_email)
            if (name_match && email_match) {
              found = 1
            }
          }
        }
      }
    }
  }
  END {
    if (found == 1) {
      exit 0
    } else {
      exit 1
    }
  }
' "${COMMIT_MSG_FILE}"; then
  if [[ "${author}" == "${committer}" ]]; then
    expected_output="  Signed-off-by: ${author}"
  else
    expected_output="  Signed-off-by: ${author}
  Signed-off-by: ${committer}"
  fi

  cat >&2 <<EOF
Error: Missing or mismatched DCO Signed-off-by trailer in commit message.

Expected:
${expected_output}

To fix this:
  Use 'git commit -s' or add a Signed-off-by trailer matching the author or committer.
EOF
  exit 1
fi
