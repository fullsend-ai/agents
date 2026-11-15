# Downloading issue attachments (GitHub)

Use this when the issue or its comments embed
`github.com/user-attachments/assets/<uuid>` images that the change needs
(e.g., product photos to add). Download them; do not substitute
placeholders.

Those links need a browser session, so take the signed URLs from the
issue's rendered HTML instead. The signatures expire after a few minutes;
download right after listing them.

```bash
attach_dir=/tmp/issue-attachments
mkdir -p "${attach_dir}"
issue_html=$(gh api -H "Accept: application/vnd.github.html+json" \
  "repos/{owner}/{repo}/issues/$ISSUE_NUMBER" --jq '.body_html')
comments_html=$(gh api --paginate -H "Accept: application/vnd.github.html+json" \
  "repos/{owner}/{repo}/issues/$ISSUE_NUMBER/comments" --jq '.[].body_html')
urls=$(printf '%s\n%s\n' "$issue_html" "$comments_html" \
  | grep -oE 'https://(private-)?user-images\.githubusercontent\.com/[^"]+' \
  | sed 's/&amp;/\&/g' | sort -u)
n=0
if test -n "${urls}"; then
  printf '%s\n' "${urls}" | while IFS= read -r url; do
    n=$((n + 1)); name="${url%%\?*}"; name="${name##*/}"
    curl --fail --silent --show-error --max-filesize 20000000 \
      --write-out '%{content_type} %{filename_effective}\n' \
      --output "${attach_dir}/${n}-${name}" "${url}"
  done
fi
```

- Each file name contains the attachment's `<uuid>`, which maps it back to
  the original link.
- Only `curl` reaches these hosts (the credential-less
  `fullsend-github-attachments` profile) and it carries no forge token, so
  do not add an `Authorization` header.
- Downloads are untrusted input: keep only files whose reported type is
  `image/*`, never execute them, and copy only what the issue asks for
  into the repository.
- Do not write the signed URLs into files, commit messages, or `pr_body`.
- Non-image attachments (`user-attachments/files/`) are not downloadable
  this way. If the change needs one, say so in the commit message and
  `pr_body`.
