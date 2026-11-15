#!/usr/bin/env bash
# after_each hook: delete the ephemeral GitHub repo.
#
# Required env (forward-propagated from setup-fixture.sh):
#   EPHEMERAL_REPO — org/name of the ephemeral repo
#
# Optional env (set by harness):
#   CASE_WORKSPACE — read for the .hook-outputs.yaml setup-fixture.sh
#                    wrote when EPHEMERAL_REPO was not forwarded
set -euo pipefail

EPHEMERAL_REPO="${EPHEMERAL_REPO:-}"
# When setup-fixture.sh fails after creating the repo, the harness runs
# after_each without collecting .hook-outputs.yaml, so the env var is unset
# but the file setup wrote is still in the case workspace.
if [[ -z "$EPHEMERAL_REPO" && -n "${CASE_WORKSPACE:-}" \
  && -f "${CASE_WORKSPACE}/.hook-outputs.yaml" ]] && command -v yq >/dev/null 2>&1; then
  EPHEMERAL_REPO="$(yq -r '.env.EPHEMERAL_REPO // ""' "${CASE_WORKSPACE}/.hook-outputs.yaml")"
fi
if [[ -z "$EPHEMERAL_REPO" ]]; then
  echo "WARNING: EPHEMERAL_REPO not set, skipping teardown" >&2
  exit 0
fi

if ! gh repo delete "$EPHEMERAL_REPO" --yes 2>&1; then
  echo "WARNING: failed to delete $EPHEMERAL_REPO — may need manual cleanup" >&2
fi
