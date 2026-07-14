#!/usr/bin/env bash
# bundle-sh.sh — Inline scripts/lib/*.lib.sh sources into a .src.sh script.
#
# Usage:
#   bundle-sh.sh [-o OUTPUT] SOURCE.src.sh
#
# Writes a self-contained .sh script with libraries inlined at each source line.
# Shebang remains line 1; a GENERATED banner is inserted on line 2.

set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: bundle-sh.sh [-o OUTPUT] SOURCE.src.sh

Bundle scripts/lib/*.lib.sh inclusions into a single executable script.
EOF
  exit 1
}

output_path=""
src_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      [[ $# -ge 2 ]] || usage
      output_path="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      [[ -z "${src_path}" ]] || usage
      src_path="$1"
      shift
      ;;
  esac
done

[[ -n "${src_path}" ]] || usage
[[ -f "${src_path}" ]] || { echo "bundle-sh: not found: ${src_path}" >&2; exit 1; }
[[ "${src_path}" == *.src.sh ]] || {
  echo "bundle-sh: source must be a .src.sh file: ${src_path}" >&2
  exit 1
}

src_abs="$(cd "$(dirname "${src_path}")" && pwd)/$(basename "${src_path}")"
src_dir="$(dirname "${src_abs}")"
src_base="$(basename "${src_abs}")"

declare -A BUNDLE_INCLUDED=()

bundle_canonical_path() {
  local path="$1"

  if command -v readlink >/dev/null 2>&1; then
    readlink -f "${path}" 2>/dev/null && return 0
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath "${path}" 2>/dev/null && return 0
  fi
  printf '%s' "${path}"
}

bundle_resolve_path() {
  local ref="$1"
  local base_dir="$2"
  local candidate=""

  if [[ "${ref}" == /* ]]; then
    candidate="${ref}"
  elif [[ "${ref}" == ./* ]]; then
    candidate="${base_dir}/${ref#./}"
  elif [[ "${ref}" == ../* ]]; then
    candidate="$(cd "${base_dir}" && cd "$(dirname "${ref}")" && pwd)/$(basename "${ref}")"
  else
    candidate="${base_dir}/${ref}"
  fi

  candidate="$(cd "$(dirname "${candidate}")" && pwd)/$(basename "${candidate}")"
  if [[ -e "${candidate}" || -L "${candidate}" ]]; then
    candidate="$(bundle_canonical_path "${candidate}")"
  fi
  printf '%s' "${candidate}"
}

bundle_is_lib() {
  local path="$1"
  [[ "${path}" == */scripts/lib/*.lib.sh ]]
}

bundle_lib_body() {
  local lib_path="$1"
  local line
  local first=true
  local -a lines

  mapfile -t lines < "${lib_path}"
  for line in "${lines[@]}"; do
    if [[ "${first}" == true && "${line}" =~ ^#! ]]; then
      first=false
      continue
    fi
    first=false

    if [[ "${line}" =~ ^[[:space:]]*source[[:space:]]+(.+)[[:space:]]*$ ]]; then
      bundle_expand_source "${BASH_REMATCH[1]}" "$(dirname "${lib_path}")"
      continue
    fi

    printf '%s\n' "${line}"
  done
}

bundle_expand_source() {
  local raw_expr="$1"
  local base_dir="$2"
  local ref=""
  local resolved=""
  local rel_comment=""

  ref="$(printf '%s' "${raw_expr}" | sed -E \
    -e 's/^[[:space:]]*"//; s/"[[:space:]]*$//' \
    -e 's/^[[:space:]]*'\''//; s/'\''[[:space:]]*$//' \
    -e 's/^\$\{SCRIPT_DIR[^}]*\}\///' \
    -e 's/^\$\{SCRIPT_DIR_POST[^}]*\}\///' \
    -e 's/^\$\{SCRIPT_DIR[^}]*\}//')"

  if [[ -z "${ref}" ]]; then
    echo "bundle-sh: unsupported source expression: ${raw_expr}" >&2
    exit 1
  fi

  if [[ "${ref}" == lib/* ]]; then
    resolved="$(bundle_resolve_path "${ref}" "${src_dir}")"
  else
    resolved="$(bundle_resolve_path "${ref}" "${base_dir}")"
  fi

  if ! bundle_is_lib "${resolved}"; then
    echo "bundle-sh: source outside scripts/lib/*.lib.sh: ${resolved}" >&2
    exit 1
  fi

  if [[ ! -f "${resolved}" ]]; then
    echo "bundle-sh: missing library: ${resolved}" >&2
    exit 1
  fi

  rel_comment="${resolved#"${src_dir}/"}"

  if [[ -n "${BUNDLE_INCLUDED[${resolved}]+x}" ]]; then
    printf '# (already bundled: %s)\n' "${rel_comment}"
    return 0
  fi

  BUNDLE_INCLUDED["${resolved}"]=1
  printf '# BEGIN bundled: %s\n' "${rel_comment}"
  bundle_lib_body "${resolved}"
  printf '# END bundled: %s\n' "${rel_comment}"
}

bundle_src_file() {
  local line=""
  local first=true
  local saw_shebang=false
  local -a lines

  mapfile -t lines < "${src_abs}"
  for line in "${lines[@]}"; do
    if [[ "${first}" == true && "${line}" =~ ^#! ]]; then
      printf '%s\n' "${line}"
      printf '# GENERATED from %s — DO NOT EDIT. Run: make script-build\n' "${src_base}"
      saw_shebang=true
      first=false
      continue
    fi
    first=false

    if [[ "${line}" =~ ^[[:space:]]*source[[:space:]]+(.+)[[:space:]]*$ ]]; then
      bundle_expand_source "${BASH_REMATCH[1]}" "${src_dir}"
      continue
    fi

    if [[ "${saw_shebang}" == false && "${line}" =~ ^#! ]]; then
      printf '%s\n' "${line}"
      printf '# GENERATED from %s — DO NOT EDIT. Run: make script-build\n' "${src_base}"
      saw_shebang=true
      continue
    fi

    printf '%s\n' "${line}"
  done
}

if [[ -n "${output_path}" ]]; then
  bundle_src_file > "${output_path}"
  chmod +x "${output_path}"
else
  bundle_src_file
fi
