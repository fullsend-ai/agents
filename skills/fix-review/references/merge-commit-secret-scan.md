# Merge-commit secret-scanning checklist

Referenced from `SKILL.md` step 4 and `agents/fix.md` ("Reconcile
forge-reported merge conflicts"). Apply **every** item before
implementing a change that introduces or modifies merge-commit conflict
resolution, or any gitleaks/secret-scan logic that touches merges. When
a review finding names one pitfall, still apply the rest. PR #1520 spent
six review rounds discovering these one at a time.

This checklist covers the post-script merge-commit scan (gitleaks
`--log-opts` / `--pipe`). The in-sandbox `scan-secrets <files>` and
`scan-secrets --staged` steps stay file-based.

Canonical record: [PR #1520](https://github.com/fullsend-ai/agents/pull/1520).

## Background

gitleaks `detect --log-opts` drives `git log -p` without `-m`. A commit
with a `Merge:` header therefore emits no patch, even under
`--first-parent`. A two-dot range `A..B` that contains a merge also
walks the merge's extra parents (historical target-branch commits this
PR did not author). Those two facts are why a merge needs its own scan
path, and why skipping any item below is a secret-scan bypass.

Current implementation lives in `scripts/post-fix.src.sh` (bundled into
`scripts/post-fix.sh`, `scripts/post-code.sh`, and
`scripts/validate-code-output.sh`).

## Checklist

### 1. Combined-diff parent-skew (`git show --cc`)

`git show --cc` (the default combined diff for a merge) omits any path
whose merge-result blob matches **any** parent. A newly added file that
cleanly matches one parent — no conflict — is never scanned.

Treat `--cc` as a narrowing optimization, not as "everything the merge
introduced." Scan each parent-diff separately, or union
`git diff <merge>^N..<merge>` across every parent N, or fall back to
`git show -m --first-parent` whenever any extra parent is untrusted.
Use `--cc` only after every extra parent is proven trusted (item 2)
**and** resurrected content is still covered (item 3).

Example: [PR #1520](https://github.com/fullsend-ai/agents/pull/1520)
round 8.

### 2. Octopus / extra-parent trust

Checking only `^2` (the second parent) is incomplete for a merge with
more than two parents. A third parent that cleanly adds a file never
appears in `--cc` and was never proven to be trusted target history.

Walk every extra parent (`^2`, `^3`, ... until `git rev-parse` fails).
Each one must independently be an ancestor of the freshly fetched,
pinned trusted-target SHA. If any extra parent is missing,
unresolvable, or not on the trusted-target line, fall back to
`git show -m --first-parent` for that merge instead of `--cc`.

Example: [PR #1520](https://github.com/fullsend-ai/agents/pull/1520)
round 9.

### 3. Reintroduction of since-deleted secrets

An ancestor check only proves an extra parent is *somewhere* in target
history, not that its tree matches the current target tip. A secret
later deleted from the tip can sit in an older trusted parent. `--cc`
then omits it because the merge-result blob matches that parent, and
the merge reintroduces the secret with no new diff lines.

When `--cc` is used, also scan content that is in HEAD but not in the
current trusted-target tip (`git diff <trusted-tip> HEAD`).

Example: [PR #1520](https://github.com/fullsend-ai/agents/pull/1520)
round 12.

### 4. Re-validate trust after every fetch

A fetch moves `origin/<target>` (or fails to). Ancestry and skip-logic
checks computed against a SHA taken before that fetch are stale
afterward. A check that requires the *new* tip to already be in HEAD
also bounces a legitimate merge whose parent is the *old* tip.

Fetch first, pin the resulting SHA, then compute every ancestry /
skip-logic check against that pin. After any later fetch, discard the
pin, re-fetch, re-pin, and re-run the checks. Use the pinned SHA, not
the mutable ref name `origin/<target>`.

When the target fast-forwards during the run, require that the merged
parent is still on the target's line (an ancestor of the new pin), not
that the new pin is already in HEAD.

Example: [PR #1520](https://github.com/fullsend-ai/agents/pull/1520)
(GitLab reconstructed-merge trust gap / skip-logic after fetch).

## Apply every item

If a review finding cites one of these pitfalls, apply all four before
committing. Patching only the named item is how PR #1520 took six
secret-scan-bypass rounds.
