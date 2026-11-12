#!/usr/bin/env bash
# make-checkout.sh DEST — turn repo/ into a git checkout whose commit id never
# changes: fixed identity, fixed dates, branch main, a GitHub origin.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="$1"
mkdir -p "${dest}"
cp -r "${here}/repo/." "${dest}/"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_AUTHOR_DATE='2026-01-01T00:00:00Z'
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q -b main "${dest}"
git -C "${dest}" add -A
git -C "${dest}" commit -q -m "fixture"
git -C "${dest}" remote add origin https://github.com/example/app.git
git -C "${dest}" update-ref refs/remotes/origin/main HEAD
