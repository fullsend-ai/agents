---
name: issue-classification
description: >-
  Procedure for classifying GitHub issues into project categories. Loads the
  organization's categories document, screens issues by title and labels,
  fetches candidate details and comments, and applies classification rules.
  Use when the gh-classify agent needs to classify issues.
---

# Issue Classification

End-to-end procedure for reading a categories document, screening GitHub
issues, and producing classification decisions. The agent prompt defines
your role and constraints; this skill defines the process.

## Step 1: Load categories

Read the categories document from `CLASSIFY_CATEGORIES_PATH`. The harness
copies it into the sandbox as `/sandbox/workspace/categories.md` when the path
is configured. Fall back through known locations, then the GitHub API:

```bash
CATEGORIES_PATH="${CLASSIFY_CATEGORIES_PATH:-categories.md}"

if [ -f "$CATEGORIES_PATH" ]; then
  cat "$CATEGORIES_PATH"
elif [ -f "/sandbox/workspace/categories.md" ]; then
  cat "/sandbox/workspace/categories.md"
elif [ -f "../$CATEGORIES_PATH" ]; then
  cat "../$CATEGORIES_PATH"
elif [ -f "target-repo/$CATEGORIES_PATH" ]; then
  cat "target-repo/$CATEGORIES_PATH"
else
  gh api "repos/$CLASSIFY_SOURCE_REPO/contents/$CATEGORIES_PATH" --jq '.content' | base64 -d
fi
```

**Stop if the document is empty or missing.** Do not proceed without
category descriptions — classification without context produces garbage.

Parse the **exact category names** from the document headings. These are
the only valid values for `workstream_category` in your output. Store
them for exact-match comparison later.

## Step 2: Build the candidate list

Check `CLASSIFY_MODE` and `CLASSIFY_ISSUE_NUMBER`:

- **If `CLASSIFY_MODE` is `single` and `CLASSIFY_ISSUE_NUMBER` is set:**
  Your candidate list is exactly ONE issue. Fetch only that issue:

  ```bash
  gh issue view "$CLASSIFY_ISSUE_NUMBER" --repo "$CLASSIFY_SOURCE_REPO" \
    --json number,title,body,labels,author,createdAt,comments
  ```

  **Skip the rest of Step 2 and Step 3 entirely.** Go directly to Step 4
  with this single issue as your only candidate.

- **Otherwise (batch modes `unclassified` or `all`):**

Fetch all open issues:

```bash
gh issue list --repo "$CLASSIFY_SOURCE_REPO" --state open \
  --json number,title,labels,author,createdAt --limit 5000
```

Then **exclude issues that are already classified** on the project
board. The pre-script identifies these on the host, but you are in a
sandbox and must discover them yourself. Query the project board to
find issues that already have a workstream category assigned:

```bash
ORG="${CLASSIFY_SOURCE_REPO%%/*}"
PROJECT_NUM="${CLASSIFY_PROJECT_NUMBER:-1}"
FIELD="${CLASSIFY_FIELD_NAME:-Workstream Category}"

# Use GH_TOKEN only. CLASSIFY_PROJECT_TOKEN is runner-only (host pre/post
# scripts) and must not be expected in the sandbox.
CLASSIFIED=$(gh api graphql --paginate -f query='
  query($org: String!, $num: Int!, $fieldName: String!, $endCursor: String) {
    organization(login: $org) {
      projectV2(number: $num) {
        items(first: 100, after: $endCursor) {
          nodes {
            content { ... on Issue { number repository { nameWithOwner } } }
            fieldValueByName(name: $fieldName) {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }' -f org="$ORG" -F num="$PROJECT_NUM" -f fieldName="$FIELD" \
  --jq '.data.organization.projectV2.items.nodes[]
    | select(.content.repository.nameWithOwner == env.CLASSIFY_SOURCE_REPO)
    | select(.fieldValueByName.name != null and .fieldValueByName.name != "")
    | .content.number' 2>/dev/null | sort -n || true)
```

If the project query fails (permissions, network), log a warning and
continue with the full issue list — the post-script will prevent
duplicate writes regardless.

Remove any issue whose number appears in `$CLASSIFIED` from your
candidate list. Only evaluate issues that are **not already classified**.

## Step 3: Screen candidates

Check `CLASSIFY_SCREEN_ISSUES` (defaults to `true`).

**If screening is enabled (`true`):** You have limited time. Do NOT call
`gh issue view` on every issue.

1. **Screen by title and labels.** Using the category descriptions from
   Step 1, identify which issues are plausible candidates that need deeper
   inspection. Skip issues whose titles clearly belong to other categories
   or are obviously off-topic.

2. **Apply category filter.** If `CLASSIFY_FILTER_CATEGORY` is set, only
   fetch details for issues that might belong in that specific category.

**If screening is disabled (`false`):** Fetch details for ALL candidate
issues from Step 2. Do not skip any based on title or labels.

**Fetch details and comments for each candidate:**

```bash
gh issue view <number> --repo "$CLASSIFY_SOURCE_REPO" \
  --json number,title,body,labels,author,createdAt,comments
```

The `comments` field returns `{author, body, createdAt}` objects.
Comments often contain critical context — decisions, scope changes,
clarifications, or re-framing that the original body lacks. For issues
with many comments, focus on the first few and last few (scope-setting
and most recent decisions).

You may batch multiple `gh issue view` calls to work efficiently.

## Step 4: Classify each candidate

For each issue you evaluate, compare the issue's title, body, comments,
labels, and context against the category descriptions. Consider:

- Descriptive sections and scope boundaries
- "What belongs here" guidance
- "What does NOT belong here" exclusions
- Signal keywords
- Comment discussion that may redefine the issue's scope
- Any classification decision guide or tiebreaker rules in the document

### Classification rules

1. **Category filter** — If `CLASSIFY_FILTER_CATEGORY` is set, you may
   only assign that exact category or `null`.

2. **Confidence threshold** — Only assign a category when your confidence
   meets `CLASSIFY_MIN_CONFIDENCE` (default 0.7). Prefer `null` over a guess.

3. **Mutual exclusivity** — One category or null per issue. Never multiple.

4. **Respect exclusion lists** — If a category explicitly excludes the
   issue's topic, do not assign it.

5. **Labels are signal, not definitive** — Always read issue content.

6. **When in doubt, don't classify** — Ambiguous → `null` with reasoning.

7. **Category names must be exact** — Use the exact strings from the
   categories document. Do not paraphrase or abbreviate.

## Step 5: Write output

Write `${FULLSEND_OUTPUT_DIR}/agent-result.json`. Only include issues
you actually evaluated. The top-level key **must** be `"classifications"`.

```bash
mkdir -p "${FULLSEND_OUTPUT_DIR}"
cat > "${FULLSEND_OUTPUT_DIR}/agent-result.json" << 'AGENT_RESULT_EOF'
{
  "classifications": [
    {
      "issue_number": 42,
      "workstream_category": "Bug fixes",
      "reasoning": "Issue reports a crash in the login flow.",
      "confidence": 0.92
    }
  ]
}
AGENT_RESULT_EOF
```

### Output fields (each object in the `"classifications"` array)

- `issue_number`: integer
- `workstream_category`: exact category name string or `null`
- `reasoning`: 1-3 sentences (max 2000 chars)
- `confidence`: float 0.0–1.0

Prioritize producing output over exhaustive analysis. If time is limited,
classify what you have and write the file.
