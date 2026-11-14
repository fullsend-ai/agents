#!/usr/bin/env bash
# write-fixture-file.sh <dest>: write stdin to <dest>, ending with exactly
# one final newline.
#
# setup-fixture.sh reads each PR file's `content` with `yq -r`, which adds
# a newline after the YAML block's own, so writing its output directly
# ended every fixture file with a blank line: a real (low) finding a review
# agent can act on, unrelated to what the case tests. Command substitution
# strips every trailing newline; printf adds back exactly one, whatever
# block style (|, |-, |+) the case uses.
set -euo pipefail
dest="${1:?destination path required}"
content="$(cat)"
printf '%s\n' "$content" > "$dest"
