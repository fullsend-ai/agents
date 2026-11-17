#!/usr/bin/env bash
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
