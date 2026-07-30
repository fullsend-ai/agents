#!/usr/bin/env bash
# gitleaks-install.lib.sh — Platform-aware gitleaks download and verification.
#
# Source from post-code.src.sh / post-fix.src.sh:
#   source "${SCRIPT_DIR_POST}/lib/gitleaks-install.lib.sh"
#
# Provides:
#   resolve_platform   — detect OS/arch and print a platform key (e.g. linux_x64)
#   gitleaks_sha256    — print the SHA-256 checksum for a given platform key
#   verify_checksum    — verify a file against an expected SHA-256 hash
#   install_gitleaks   — download, verify, and install the gitleaks binary
#
# Uses case statements (not declare -A / mapfile) so the script runs on
# bash 3.2 (macOS system bash).

# shellcheck shell=bash

[[ -n "${GITLEAKS_INSTALL_SH_LOADED:-}" ]] && return 0
GITLEAKS_INSTALL_SH_LOADED=1

GITLEAKS_VERSION="8.30.1"

gitleaks_sha256() {
  case "$1" in
    linux_x64)    echo "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb" ;;
    linux_arm64)  echo "e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080" ;;
    darwin_x64)   echo "dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709" ;;
    darwin_arm64) echo "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5" ;;
    *) return 1 ;;
  esac
}

resolve_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "${os}" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *)
      echo "::error::Unsupported OS for gitleaks: ${os}" >&2
      return 1
      ;;
  esac

  case "${arch}" in
    x86_64|amd64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      echo "::error::Unsupported architecture for gitleaks: ${arch}" >&2
      return 1
      ;;
  esac

  echo "${os}_${arch}"
}

verify_checksum() {
  local file="$1"
  local expected="$2"

  if command -v sha256sum >/dev/null 2>&1; then
    echo "${expected}  ${file}" | sha256sum -c -
  elif command -v shasum >/dev/null 2>&1; then
    echo "${expected}  ${file}" | shasum -a 256 -c -
  else
    echo "::error::Neither sha256sum nor shasum found — cannot verify gitleaks checksum" >&2
    return 1
  fi
}

install_gitleaks() {
  if command -v gitleaks >/dev/null 2>&1; then
    return 0
  fi

  echo "Installing gitleaks v${GITLEAKS_VERSION}..."
  local platform checksum tarball
  platform="$(resolve_platform)"
  checksum="$(gitleaks_sha256 "${platform}" || true)"
  if [ -z "${checksum}" ]; then
    echo "::error::No gitleaks checksum for platform: ${platform}" >&2
    return 1
  fi
  mkdir -p "${HOME}/.local/bin"
  tarball="$(mktemp)"
  if ! curl -fsSL \
       "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${platform}.tar.gz" \
       -o "${tarball}" \
     || ! verify_checksum "${tarball}" "${checksum}" \
     || ! tar xzf "${tarball}" -C "${HOME}/.local/bin" gitleaks; then
    rm -f "${tarball}"
    echo "::error::Failed to download and verify gitleaks v${GITLEAKS_VERSION} (${platform})" >&2
    return 1
  fi
  rm -f "${tarball}"
  export PATH="${HOME}/.local/bin:${PATH}"
}
