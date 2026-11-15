#!/usr/bin/env bash
# ShellCheck: split normalized PR numbers on spaces; chained failures are intentional.
# shellcheck disable=SC2013,SC2015
# DEP_PRS: space-separated candidate PR numbers in this repo. Prints
# "SCOPED: ..." and narrows pr-diff.txt to this PR's own commits, or
# prints "SKIP: <reason>" and leaves pr-diff.txt as the full diff.
# Unexpected artifact errors abort: never dispatch using a partial scope.
set -e
W=/sandbox/workspace/dep-scope
mkdir -p "$W" || exit 1
# Restore the pinned full diff before retrying. Never overwrite its backup.
if test -e /sandbox/workspace/pr-full-diff.txt; then
  if ! test "$(cat "$W/full-head" 2>/dev/null)" = "${PINNED_SHA:-}"; then
    echo "FAILURE: full diff provenance unavailable; refetch PR inputs before dispatch" >&2; exit 1
  fi
  cp /sandbox/workspace/pr-full-diff.txt "$W/restore.diff" && mv "$W/restore.diff" /sandbox/workspace/pr-diff.txt \
    || { echo "FAILURE: cannot restore full diff; stop review" >&2; exit 1; }
fi
: > "$W/dep-prs"; : > "$W/dep-shas"; : > "$W/dep-pids"
# Current-head approval plus repository policy; incomplete evidence cannot scope.
dependency_data() {
  gh api graphql -f owner="${REPO_FULL_NAME%/*}" -f name="${REPO_FULL_NAME#*/}" -F number="$1" -f query='
    query($owner:String!,$name:String!,$number:Int!) { repository(owner:$owner,name:$name) { pullRequest(number:$number) {
      state isDraft baseRefName baseRefOid headRefOid author { login } reviewDecision
      latestReviews(first:100) { pageInfo { hasNextPage } nodes { state authorCanPushToRepository author { login } commit { oid } } }
    } } }'
}
SKIP=""
DIFF_ACCEPT="Accept: application/vnd.github.diff"
# DEP_PRS comes from untrusted PR text; split it without pathname expansion.
set -f
gh api "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}" > "$W/own.json" || SKIP="cannot determine PR head SHA"
if test -z "$SKIP"; then
  test "$(jq -r '.head.sha' "$W/own.json")" = "${PINNED_SHA:-}" || SKIP="PR head moved since step 1"
fi
gh api --paginate --slurp "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}/commits?per_page=100" > "$W/own-pages.json" || SKIP="cannot list PR commits"
jq -e 'add // [] | length > 0 and length < 250 and all(.[]; (.parents | length) == 1)' "$W/own-pages.json" >/dev/null 2>&1 \
  || SKIP="${SKIP:-PR has merge commits, no commits, or 250+ commits}"
if test -z "$SKIP"; then
  for d in ${DEP_PRS:-}; do
    printf '%s' "$d" | grep -Eqx '[1-9][0-9]*' || { SKIP="malformed dependency PR number"; break; }
    dependency_data "$d" > "$W/dep-$d-meta.json" || { SKIP="cannot verify dependency #$d"; break; }
    STATE=$(jq -r '.data.repository.pullRequest.state' "$W/dep-$d-meta.json")
    if test "$STATE" = CLOSED || test "$STATE" = MERGED; then echo "#$d is not open: not a dependency"; continue; fi
    jq -e --slurpfile own "$W/own.json" '
      .errors == null and (.data.repository.pullRequest | . as $pr |
      .state == "OPEN" and .isDraft == false and .baseRefName == $own[0].base.ref
      and (.headRefOid | type == "string" and length > 0) and .reviewDecision == "APPROVED"
      and .latestReviews.pageInfo.hasNextPage == false
      and any(.latestReviews.nodes[]; .state == "APPROVED" and .commit.oid == $pr.headRefOid
        and .authorCanPushToRepository == true and .author.login != $pr.author.login)
      and all(.latestReviews.nodes[]; .state != "CHANGES_REQUESTED"))' "$W/dep-$d-meta.json" >/dev/null 2>&1 \
      || { SKIP="dependency #$d is not verified at its current head"; break; }
    echo "$d" >> "$W/dep-prs"
    if ! gh api --paginate --slurp "repos/${REPO_FULL_NAME}/pulls/$d/commits?per_page=100" < /dev/null > "$W/dep-$d.json"; then
      SKIP="cannot list #$d commits"; break
    fi
    if ! jq -e 'type == "array" and length > 0 and all(.[]; type == "array")
      and (add | type == "array" and length > 0 and length < 250
        and all(.[]; type == "object" and (.sha | type) == "string" and (.sha | length) > 0))' "$W/dep-$d.json" >/dev/null 2>&1; then
      SKIP="#$d has invalid or 250+ commits"; break
    fi
    jq -r 'add | .[].sha' "$W/dep-$d.json" >> "$W/dep-shas" 2>/dev/null
  done
fi
test -s "$W/dep-prs" || SKIP="${SKIP:-no open dependency PR}"
# ids <sha>: prints "<stable patch-id> <exact hash of changed lines and newline markers>".
# It prints nothing for a fetched diff with no patch ID; that commit is not a
# patch-match candidate.
ids() {
  gh api -H "$DIFF_ACCEPT" "repos/${REPO_FULL_NAME}/commits/$1" < /dev/null > "$W/one.diff" || return 1
  PID=$(git patch-id --stable < "$W/one.diff") || return 1
  PID=${PID%% *}
  test -n "$PID" || return 0
  EXACT=$(grep -E '^([-+]|\\ No newline at end of file)' "$W/one.diff" | sha256sum | cut -d' ' -f1) || return 1
  # No pipefail: a failed hash step leaves an empty value, so require well-formed hashes.
  printf '%s\n' "$PID" | grep -Eqx '[0-9a-f]{40,64}' || return 1
  printf '%s\n' "$EXACT" | grep -Eqx '[0-9a-f]{64}' || return 1
  echo "$PID $EXACT"
}
if test -z "$SKIP"; then
  jq -r 'add // [] | .[].sha' "$W/own-pages.json" > "$W/own-shas"
  test "$(tail -1 "$W/own-shas")" = "${PINNED_SHA:-}" || SKIP="PR commit list does not end at pinned head"
  while IFS= read -r s; do
    # Exact SHAs establish identity without a patch diff. This also lets an
    # empty exact-SHA commit match even though git patch-id emits no output.
    if grep -qxF -e "$s" "$W/own-shas"; then continue; fi
    ID=$(ids "$s") || SKIP="${SKIP:-cannot compare patches of dependency commits}"
    if test -n "$ID"; then echo "$ID"; fi
  done < "$W/dep-shas" > "$W/dep-pids"
  while IFS= read -r s; do
    if grep -qxF -e "$s" "$W/dep-shas"; then echo "dep $s"; continue; fi
    ID=$(ids "$s") || SKIP="${SKIP:-cannot compare patches of own commits}"
    if test "${ID%% *}" != "" && grep -qxF -e "$ID" "$W/dep-pids"; then echo "dep $s"; else echo "own $s"; fi
  done < "$W/own-shas" > "$W/classified"
  SHAPE=$(cut -d' ' -f1 "$W/classified" | uniq | tr '\n' ' ')
  test "$SHAPE" = "dep own " || SKIP="${SKIP:-commits are not dependency commits followed by own commits (${SHAPE})}"
fi
if test -z "$SKIP"; then
  grep '^dep ' "$W/classified" | cut -d' ' -f2 > "$W/prefix-shas"
  MATCH=""
  for d in $(cat "$W/dep-prs"); do
    jq -r 'add | .[].sha' "$W/dep-$d.json" > "$W/candidate-shas"
    LAST_DEP=$(tail -1 "$W/prefix-shas")
    test "$(tail -1 "$W/candidate-shas")" = "$(jq -r '.data.repository.pullRequest.headRefOid' "$W/dep-$d-meta.json")" || continue
    if cmp -s "$W/prefix-shas" "$W/candidate-shas"; then MATCH="$d"; break; fi
    test "$(wc -l < "$W/prefix-shas")" = "$(wc -l < "$W/candidate-shas")" || continue
    paste "$W/prefix-shas" "$W/candidate-shas" > "$W/pairs"
    MATCH="$d"
    OTHER=""
    while read -r s t; do
      if test "$s" = "$t"; then continue; fi
      ID=$(ids "$s") && OTHER=$(ids "$t") || { MATCH=""; break; }
      if test -z "$ID" || test "$ID" != "$OTHER"; then MATCH=""; break; fi
    done < "$W/pairs"
    test -n "$MATCH" || continue
    # Ordered commit matches alone do not prove equivalent net changes.
    # Keep hunk locations, context, whitespace, and operation metadata.
    BASE_SHA=$(jq -r '.base.sha' "$W/own.json")
    DEP_BASE=$(jq -r '.data.repository.pullRequest.baseRefOid' "$W/dep-$d-meta.json")
    DEP_HEAD=$(jq -r '.data.repository.pullRequest.headRefOid' "$W/dep-$d-meta.json")
    NET_N=$(wc -l < "$W/prefix-shas")
    NET_COMPLETE='(.status == "ahead" or .status == "identical") and .behind_by == 0
      and .total_commits == $expected
      and (.files | type == "array" and length < 300)
      and all(.files[]; .patch | type == "string" and length > 0)'
    if ! gh api "repos/${REPO_FULL_NAME}/compare/${BASE_SHA}...${LAST_DEP}" > "$W/prefix-net.json" \
      || ! gh api "repos/${REPO_FULL_NAME}/compare/${DEP_BASE}...${DEP_HEAD}" > "$W/dependency-net.json" \
      || ! jq -e --argjson expected "$NET_N" "$NET_COMPLETE" "$W/prefix-net.json" >/dev/null \
      || ! jq -e --argjson expected "$NET_N" "$NET_COMPLETE" "$W/dependency-net.json" >/dev/null; then MATCH=""; continue; fi
    if ! gh api -H "$DIFF_ACCEPT" "repos/${REPO_FULL_NAME}/compare/${BASE_SHA}...${LAST_DEP}" > "$W/prefix.diff" \
      || ! gh api -H "$DIFF_ACCEPT" "repos/${REPO_FULL_NAME}/compare/${DEP_BASE}...${DEP_HEAD}" > "$W/dependency.diff"; then MATCH=""; continue; fi
    if grep -Eq '^(Binary files |GIT binary patch)' "$W/prefix.diff" "$W/dependency.diff"; then MATCH=""; continue; fi
    if ! sed '/^index /d' "$W/prefix.diff" > "$W/prefix-exact.diff" \
      || ! sed '/^index /d' "$W/dependency.diff" > "$W/dependency-exact.diff"; then MATCH=""; continue; fi
    if cmp -s "$W/prefix-exact.diff" "$W/dependency-exact.diff"; then break; fi
    MATCH=""
  done
  test -n "$MATCH" || SKIP="excluded prefix is not a complete dependency"
  if test -n "$MATCH"; then echo "$MATCH" > "$W/dep-prs"; fi
fi
if test -z "$SKIP"; then
  LAST_DEP=$(grep '^dep ' "$W/classified" | tail -1 | cut -d' ' -f2)
  # PINNED_SHA is the step 1 head SHA (shell variables do not survive between
  # calls). Scope only if the live head still matches it.
  HEAD_SHA=$(gh api "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}" < /dev/null | jq -r '.head.sha // empty' 2>/dev/null)
  if test -z "$HEAD_SHA"; then SKIP="cannot determine PR head SHA"
  elif test "$HEAD_SHA" != "${PINNED_SHA:-}"; then SKIP="PR head moved since step 1"
  else
    gh api "repos/${REPO_FULL_NAME}/compare/${LAST_DEP}...${PINNED_SHA}" > "$W/compare.json" || SKIP="compare failed"
    gh api -H "$DIFF_ACCEPT" "repos/${REPO_FULL_NAME}/compare/${LAST_DEP}...${PINNED_SHA}" > "$W/compare.diff" || SKIP="${SKIP:-compare diff failed}"
  fi
fi
if test -z "$SKIP"; then
  jq -e 'def safe_path: type == "string" and length > 0 and test("^[ -~]+$") and (test("(^/|/$|//|(^|/)\\.\\.?(/|$)|[\\\\\\r\\n<>])") | not);
    .status == "ahead" and .behind_by == 0 and (.files | length) > 0 and (.files | length) < 300
    and all(.files[]; (.patch | type == "string" and length > 0) and (.filename | safe_path)
      and (.previous_filename == null or (.previous_filename | safe_path)))' "$W/compare.json" >/dev/null 2>&1 \
    || SKIP="compare incomplete (binary or oversized patch, 300+ files, or unsafe path)"
fi
if test -z "$SKIP"; then
  dependency_data "$MATCH" > "$W/dep-final.json" \
    && cmp -s "$W/dep-$MATCH-meta.json" "$W/dep-final.json" || SKIP="dependency review or head moved during scoping"
  gh api "repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}" > "$W/own-final.json" \
    && jq -e --slurpfile initial "$W/own.json" '.head.sha == $initial[0].head.sha and .base.ref == $initial[0].base.ref and .base.sha == $initial[0].base.sha' "$W/own-final.json" >/dev/null \
    || SKIP="PR head or base moved during scoping"
fi
if test -z "$SKIP"; then
  # Prepare every artifact before atomically replacing the ordinary diff.
  if ! cp "$W/compare.diff" "$W/pr-diff.txt" \
    || ! jq -r '.files[].filename' "$W/compare.json" > "$W/files"; then
    echo "SKIP: cannot prepare scoped artifacts"; exit 0
  fi
  if ! test -e /sandbox/workspace/pr-full-diff.txt; then
    cp /sandbox/workspace/pr-diff.txt "$W/full.diff" \
      && mv "$W/full.diff" /sandbox/workspace/pr-full-diff.txt \
      && printf '%s\n' "$PINNED_SHA" > "$W/full-head" \
      || { echo "SKIP: cannot preserve full diff"; exit 0; }
  fi
  cp "$W/pr-diff.txt" "$W/publish.diff" && mv "$W/publish.diff" /sandbox/workspace/pr-diff.txt \
    || { echo "SKIP: cannot publish scoped diff"; exit 0; }
  OWN_N=$(grep -c '^own ' "$W/classified")
  DEP_N=$(grep -c '^dep ' "$W/classified")
  echo "SCOPED: $OWN_N own commit(s) after $LAST_DEP; $DEP_N dependency commit(s) from: $(tr '\n' ' ' < "$W/dep-prs")"
else
  echo "SKIP: $SKIP"
fi
