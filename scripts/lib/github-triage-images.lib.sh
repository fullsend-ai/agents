#!/usr/bin/env bash
# shellcheck shell=bash
# github-triage-images.lib.sh — Stage authorized issue images for triage.
#
# Bundled into pre-triage.sh. On GitHub, triage looks at the images attached
# to the issue body and its comments (agents/triage.md Step 1a). Only images
# posted by the issue author, or by a user whose role on the repository is
# admin, maintain or write, may reach the model (#2172). This runs on the
# runner, before the sandbox exists: it checks each poster, downloads the
# allowed images and writes them, with a manifest, to
# ${RUNNER_TEMP}/fullsend-triage-images. harness/triage.yaml copies each file
# into the sandbox with an optional host_files entry; the sandbox itself has
# no route to the image hosts.
#
# An image is left out when its poster lacks the role and when the
# permission lookup fails. The manifest counts those images so the triage
# comment can report them.
#
# Expected globals (set by tracker_parse_issue_url):
#   REPO         — owner/repo
#   ISSUE_NUMBER — issue number
#
# Expected env vars:
#   GH_TOKEN     — GitHub token that can read the issue and its comments
#   RUNNER_TEMP  — runner temp directory (set by GitHub Actions)

[[ -n "${GITHUB_TRIAGE_IMAGES_SH_LOADED:-}" ]] && return 0
GITHUB_TRIAGE_IMAGES_SH_LOADED=1

# harness/triage.yaml mounts manifest.json and image-1 .. image-10 from this
# directory; keep the names and the limit in sync with it.
TRIAGE_IMAGES_MAX=10

# _triage_image_role_allows ROLE_NAME PERMISSION — succeed for admin,
# maintain and write. The collaborator permission endpoint reports maintain
# as permission "write" and triage as "read", so built-in role names are
# cross-checked against permission and a custom role falls back to its base
# permission, as fullsend's e2e gate does (internal/e2eauth/role.go).
_triage_image_role_allows() {
  local role_name="$1" permission="$2"
  case "${role_name}" in
    admin) [[ "${permission}" == "admin" ]] ;;
    maintain|write) [[ "${permission}" == "write" ]] ;;
    triage|read) return 1 ;;
    *) [[ "${permission}" == "admin" || "${permission}" == "write" ]] ;;
  esac
}

# _triage_image_poster_allowed LOGIN — succeed when LOGIN has the admin,
# maintain or write role on REPO. A login that is not a plain user name
# (empty for a deleted account, or a bot) and a failed lookup both fail.
_triage_image_poster_allowed() {
  local login="$1" fields role_name permission
  [[ "${login}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || return 1
  fields=$(gh api "repos/${REPO}/collaborators/${login}/permission" \
    --jq '[(.role_name // ""), (.permission // "")] | @tsv' 2>/dev/null) || return 1
  IFS=$'\t' read -r role_name permission <<< "${fields}"
  _triage_image_role_allows "${role_name}" "${permission}"
}

# _triage_image_download URL OUT — download URL to OUT without credentials
# and print its content type. Never prints the URL: private image URLs carry
# a signed token.
_triage_image_download() {
  local url="$1" out="$2"
  curl --fail --silent --proto '=https' --max-time 60 --max-filesize 20000000 \
    --output "${out}" --write-out '%{content_type}' "${url}" 2>/dev/null
}

# triage_stage_issue_images — write the allowed images and manifest.json to
# ${RUNNER_TEMP}/fullsend-triage-images. Never fails the run: when the images
# cannot be listed, no manifest is written and triage runs without images.
triage_stage_issue_images() {
  if [[ -z "${RUNNER_TEMP:-}" ]]; then
    echo "::warning::RUNNER_TEMP is not set — no issue images staged for triage"
    return 0
  fi
  local dir="${RUNNER_TEMP}/fullsend-triage-images"
  # A runner that reuses its host could keep an earlier run's images.
  rm -rf "${dir}"
  if ! mkdir -p "${dir}"; then
    echo "::warning::Cannot create the issue image directory — no issue images staged for triage"
    return 0
  fi

  local work
  if ! work=$(mktemp -d); then
    echo "::warning::Cannot create a work directory — no issue images staged for triage"
    return 0
  fi
  local issue_json="${work}/issue.json" comments_json="${work}/comments.json"
  # posts.tsv: poster, source, URL. A deleted account's empty login is
  # written as "-" so the tab-separated fields stay aligned.
  local posts="${work}/posts.tsv" entries="${work}/entries.jsonl"
  local imgs='def imgs: [(.body_html // "") | scan("src=\"(https://(?:private-)?user-images\\.githubusercontent\\.com/[A-Za-z0-9._~%&;=?/:+-]+)\"") | .[0] | gsub("&amp;"; "&")] | unique | .[];'
  local author
  if ! gh api -H "Accept: application/vnd.github.html+json" \
        "repos/${REPO}/issues/${ISSUE_NUMBER}" > "${issue_json}" 2>/dev/null \
      || ! gh api --paginate -H "Accept: application/vnd.github.html+json" \
        "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" > "${comments_json}" 2>/dev/null \
      || ! author=$(jq -r '.user.login // ""' "${issue_json}" 2>/dev/null) \
      || ! jq -r "${imgs}"' . as $i | ($i | imgs) | [(if ($i.user.login // "") == "" then "-" else $i.user.login end), "issue body", .] | @tsv' \
        "${issue_json}" > "${posts}" 2>/dev/null \
      || ! jq -r "${imgs}"' .[] | . as $c | ($c | imgs) | [(if ($c.user.login // "") == "" then "-" else $c.user.login end), "comment", .] | @tsv' \
        "${comments_json}" >> "${posts}" 2>/dev/null; then
    echo "::warning::Cannot list the images attached to the issue — no issue images staged for triage"
    rm -rf "${work}"
    return 0
  fi
  : > "${entries}"

  local url_re='^https://(private-)?user-images\.githubusercontent\.com/[A-Za-z0-9._~%&;=?/:+-]+$'
  local allowed_logins=$'\n' denied_logins=$'\n'
  local omitted=0 unreadable=0 attempted=0 staged=0
  local poster source url path ext ctype out
  while IFS=$'\t' read -r poster source url; do
    [[ "${url}" =~ ${url_re} ]] || continue
    path="${url%%\?*}"
    ext="${path##*.}"
    case "$(printf '%s' "${ext}" | tr '[:upper:]' '[:lower:]')" in
      svg|mp4|mov|webm) continue ;;
    esac

    if [[ -z "${author}" || "${poster}" != "${author}" ]]; then
      if [[ "${denied_logins}" == *$'\n'"${poster}"$'\n'* ]]; then
        omitted=$((omitted + 1))
        continue
      fi
      if [[ "${allowed_logins}" != *$'\n'"${poster}"$'\n'* ]]; then
        if _triage_image_poster_allowed "${poster}"; then
          allowed_logins+="${poster}"$'\n'
        else
          denied_logins+="${poster}"$'\n'
          omitted=$((omitted + 1))
          continue
        fi
      fi
    fi

    [[ "${attempted}" -lt "${TRIAGE_IMAGES_MAX}" ]] || continue
    attempted=$((attempted + 1))
    out="${dir}/image-${attempted}"
    ctype=""
    if ctype=$(_triage_image_download "${url}" "${out}"); then
      ctype="$(printf '%s' "${ctype%%;*}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    else
      ctype=""
    fi
    case "${ctype}" in
      image/png|image/jpeg|image/gif|image/webp)
        jq -nc --arg file "image-${attempted}" --arg source "${source}" \
          --arg posted_by "${poster}" --arg content_type "${ctype}" \
          '{file: $file, source: $source, posted_by: $posted_by, content_type: $content_type}' >> "${entries}"
        staged=$((staged + 1))
        ;;
      *)
        rm -f "${out}"
        unreadable=$((unreadable + 1))
        ;;
    esac
  done < "${posts}"

  if ! jq -n --slurpfile images "${entries}" --argjson omitted "${omitted}" \
      --argjson unreadable "${unreadable}" \
      '{images: $images, omitted: $omitted, unreadable: $unreadable}' > "${dir}/manifest.json"; then
    echo "::warning::Cannot write the issue image manifest — no issue images staged for triage"
    rm -rf "${dir}" "${work}"
    return 0
  fi
  rm -rf "${work}"
  echo "Issue images: ${staged} staged, ${omitted} left out (poster not authorized), ${unreadable} unreadable"
}
