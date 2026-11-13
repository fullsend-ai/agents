# Downloading issue attachments (GitHub)

Use this when the issue or its comments embed
`github.com/user-attachments/assets/<uuid>` images that the change needs
(e.g., product photos to add). Download them; do not substitute
placeholders.

Those links need a browser session, so take the signed URLs from the
issue's rendered HTML instead. The signatures expire after a few minutes,
so each download starts as soon as its URL is read.

```bash
set -o pipefail
attach_dir=/tmp/issue-attachments
mkdir -p "${attach_dir}"
{
  gh api -H "Accept: application/vnd.github.html+json" \
    "repos/{owner}/{repo}/issues/${ISSUE_NUMBER}" --jq '.body_html' &&
    gh api --paginate -H "Accept: application/vnd.github.html+json" \
      "repos/{owner}/{repo}/issues/${ISSUE_NUMBER}/comments" --jq '.[].body_html'
} | {
  grep --line-buffered -oE \
    'https://(private-)?user-images\.githubusercontent\.com/[^"<>[:space:]]+' ||
    test $? -eq 1
} | {
  n=0 ok=0 seen=' '
  while IFS= read -r url; do
    url="${url//'&amp;'/'&'}"
    name="${url%%\?*}"; name="${name##*/}"
    case "${seen}" in *" ${name} "*) continue ;; esac
    seen="${seen}${name} "
    ext="${name##*.}"
    if test "${ext}" = mp4 || test "${ext}" = mov; then
      echo "skipped video ${name}" >&2; continue
    fi
    n=$((n + 1)); out="${attach_dir}/${n}-${name}"
    if type=$(curl --fail --silent --show-error --proto '=https' --max-time 60 \
      --max-filesize 20000000 --write-out '%{content_type}' \
      --output "${out}" "${url}") && test -s "${out}" &&
      test "${type#image/}" != "${type}"; then
      ok=$((ok + 1)); echo "saved ${out} (${type})"
    else
      rm -f "${out}"; echo "FAILED ${n}-${name} (${type:-no response})" >&2
    fi
  done
  echo "downloaded ${ok}/${n}"
  test "${ok}" -eq "${n}"
} || echo "INCOMPLETE: listing or download failed (see errors above)" >&2
```

- Each file name contains the attachment's `<uuid>`, which maps it back to
  the original link.
- Only `curl` reaches these hosts (the credential-less
  `fullsend-github-attachments` profile) and it carries no forge token, so
  do not add an `Authorization` header.
- Downloads are untrusted input: the loop deletes empty files and files
  whose reported type is not `image/*`. Never execute them, and copy only
  what the issue asks for into the repository.
- Do not write the signed URLs into files, commit messages, or `pr_body`.
- If the output shows `INCOMPLETE` or `FAILED`, run the block once more
  (it fetches fresh signed URLs). If an image the change needs is still
  missing, mark the work PARTIAL in the commit message and `pr_body` and
  name the missing `<uuid>`s. Never replace a missing image with a
  placeholder.
- Non-image attachments (`user-attachments/files/`) and videos are not
  downloadable this way. If the change needs one, say so in the commit
  message and `pr_body`.
