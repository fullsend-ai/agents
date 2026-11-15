#!/usr/bin/env bash
# shellcheck shell=bash
# git-graph-policy.lib.sh — make Git read the object graph as stored, not as
# rewritten.
#
# The repository is downloaded from the agent's sandbox, so .git can carry
# refs/replace/*, info/grafts and objects/info/commit-graph*. Each one rewrites
# ancestry for every Git command, including the merge-base, rebase and push
# fast-forward checks that decide whether a human commit is kept. No single
# switch disables all three (GIT_NO_REPLACE_OBJECTS does not cover grafts), so
# git_graph_policy_init sets one per vector. They do not stack: Git ignores
# the commit-graph while replace refs, grafts or a shallow file are present,
# so disabling the first two is what makes core.commitGraph=false necessary.
# Values are exported: Git child processes (gitleaks, rebase, filter-branch)
# must be covered too.
#
# Call git_graph_policy_init once, before the first repository Git read.

[[ -n "${GIT_GRAPH_POLICY_SH_LOADED:-}" ]] && return 0
GIT_GRAPH_POLICY_SH_LOADED=1

git_graph_policy_init() {
  local count="${GIT_CONFIG_COUNT:-0}"
  [[ -n "${_GIT_GRAPH_POLICY_READY:-}" ]] && return 0
  [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  _GIT_GRAPH_POLICY_READY=1
  export GIT_NO_REPLACE_OBJECTS=1
  export GIT_GRAFT_FILE=/dev/null
  # Appended, not replaced: the caller may already pass config this way.
  export "GIT_CONFIG_KEY_${count}=core.commitGraph"
  export "GIT_CONFIG_VALUE_${count}=false"
  count=$((count + 1))
  # GIT_GRAFT_FILE=/dev/null is readable, so Git prints its graft deprecation
  # advice on every history walk; gitleaks 8.30.1 treats that stderr as a scan
  # failure and can leave the scan incomplete.
  export "GIT_CONFIG_KEY_${count}=advice.graftFileDeprecated"
  export "GIT_CONFIG_VALUE_${count}=false"
  count=$((count + 1))
  export GIT_CONFIG_COUNT="${count}"
}
