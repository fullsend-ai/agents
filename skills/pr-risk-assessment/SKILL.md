---
name: pr-risk-assessment
description: >-
  Computes composite PR risk score from metadata, git history, and linked
  issue signals. Three-tier scoring model: metadata 50%, git history 30%,
  linked issue 20% (redistributed to 62/38 when no issue linked). Outputs
  JSON risk object with score (1-5), level (low/moderate/elevated/high/critical),
  tier signals, and rationale.
---

# PR Risk Assessment Scoring Model

This skill defines the composite risk scoring model for pull requests.
It combines metadata signals (Tier 1), git history analysis (Tier 2),
and linked issue context (Tier 3) into a single 1-5 risk score with a
categorical level.

## Scoring Model

The composite risk score is a weighted average of three tiers:

- **Tier 1 (Metadata):** 50% — deterministic signals extracted by script
- **Tier 2 (Git History):** 30% — churn analysis, author diversity, fix/revert patterns
- **Tier 3 (Linked Issue):** 20% — issue scope, labels, acceptance criteria

**Redistribution rule:** When no linked issue context is available,
redistribute tier weights to 62% (Tier 1) and 38% (Tier 2). Tier 3
contributes 0.

Each tier produces a sub-score on a 1-5 scale. The composite score is
the weighted sum, rounded to the nearest integer.

**Score-to-level mapping:**
- **1 = low** — routine change, minimal risk
- **2 = moderate** — standard review adequate
- **3 = elevated** — requires careful review
- **4 = high** — requires expert review
- **5 = critical** — requires multi-reviewer consensus

## Tier 1: Metadata Signals

The `risk-tier1.sh` script outputs these KEY=VALUE signals. Evaluate
each dimension and assign a 1-5 sub-score. Then average the sub-scores
for the Tier 1 composite.

| Signal | Meaning | Scoring Guidance (1-5) |
|--------|---------|------------------------|
| `FILES_CHANGED` | Number of files modified | 1-3 files = 1, 4-10 = 2, 11-25 = 3, 26-50 = 4, >50 = 5 |
| `LINES_CHANGED` | Total lines added + deleted | <100 = 1, 100-299 = 2, 300-799 = 3, 800-1999 = 4, ≥2000 = 5 |
| `BLAST_RADIUS` | Size classification | small = 1, medium = 3, large = 5 |
| `PROTECTED_PATH_COUNT` | Count of protected path changes | 0 = 1, 1 = 3, ≥2 = 5 |
| `SECURITY_SENSITIVE_COUNT` | Count of security-sensitive path changes | 0 = 1, 1 = 3, 2-3 = 4, ≥4 = 5 |
| `CI_WORKFLOW_CHANGED` | Boolean: CI/workflow files changed | false = 1, true = 4 |
| `DEPENDENCY_FILES_CHANGED` | List of dependency files (comma-separated) or "none" | none = 1, 1 file = 3, ≥2 files = 5 |
| `TEST_FILE_RATIO` | Ratio of test files to total files (0.00-1.00) | ≥0.50 = 1, 0.30-0.49 = 2, 0.10-0.29 = 3, 0.01-0.09 = 4, 0.00 = 5 |
| `AUTHOR_IS_BOT` | Boolean: authored by bot account | true = 1, false = 2 |
| `AUTHOR_IS_FIRST_TIME` | Boolean: first-time contributor | false = 1, true = 4 |

**Handling UNKNOWN values:** If a signal is `UNKNOWN`, skip it when
computing the Tier 1 average (do not count it as 0 or any default).
Only average the successfully computed sub-scores.

## Tier 2: Git History Signals

For each file in the PR's changed file list, run git log commands to
evaluate churn, author diversity, and fix/revert patterns. Aggregate
the file-level results into dimension scores.

| Dimension | Command | Scoring Guidance (1-5) |
|-----------|---------|------------------------|
| **Churn hotspot** | `git log --since="30 days ago" --oneline -- <file>` | Count commits in last 30 days per file. Average across files. <2 = 1, 2-5 = 2, 6-10 = 3, 11-20 = 4, >20 = 5 |
| **Multi-author contention** | `git log --since="90 days ago" --format="%ae" -- <file> \| sort -u \| wc -l` | Average distinct authors per file. 1 = 1, 2 = 2, 3-4 = 3, 5-7 = 4, >7 = 5 |
| **Recent regression history** | `git log --since="90 days ago" --oneline --grep="fix\|revert" --regexp-ignore-case -- <file>` | Count fix/revert commits per file. Average across files. 0 = 1, 1 = 2, 2-3 = 3, 4-6 = 4, >6 = 5 |
| **Code age/stability** | `git log -1 --format="%ci" -- <file>` | Days since last commit. Average across files. <7d = 1, 7-30d = 2, 31-90d = 3, 91-180d = 4, >180d = 5 |
| **Change coupling** | `git log --since="90 days ago" --format="%H" -- <file> \| xargs -I{} git show --name-only --format="" {} \| sort \| uniq -c \| sort -rn` | For each changed file, identify other files frequently modified together. Count files with coupling ≥3 co-commits missing from PR. Average across files. 0 = 1, 1 = 2, 2-3 = 3, 4-6 = 4, >6 = 5 |
| **Revert frequency** | `git log --all --oneline --grep="revert.*<file>" --regexp-ignore-case` | Count reverts on touched files (search commit messages for "revert" + file path). Average across files. 0 = 1, 1 = 2, 2-3 = 3, 4-6 = 4, >6 = 5 |
| **Commit message sentiment** | `git log --since="90 days ago" --oneline -- <file> \| grep -iE "workaround\|hack\|temporary\|todo\|fixme"` | Count commits with workaround/hack/temporary sentiment per file. Average across files. 0 = 1, 1 = 2, 2-3 = 3, 4-6 = 4, >6 = 5 |

**Procedure:** For each dimension, compute the per-file value, then
average across all changed files. Round the average to the nearest
integer for the dimension sub-score. Then average the seven dimension
sub-scores for the Tier 2 composite.

**Error handling:** If a file does not exist in git history (e.g., newly
added), skip it for Tier 2 analysis. If all files are new, Tier 2 = 2
(moderate baseline).

## Tier 3: Linked Issue Signals

If the PR description or metadata links to an issue, evaluate these
dimensions. If no issue is linked, Tier 3 does not contribute (weight
redistributed to Tiers 1 and 2).

| Dimension | Evaluation Criteria | Scoring Guidance (1-5) |
|-----------|---------------------|------------------------|
| **Complexity vs scope mismatch** | Compare issue description scope to PR file/line count | Scope matches size = 1, slightly larger = 2, moderate mismatch = 3, significant mismatch = 4, PR much larger than issue scope = 5 |
| **Issue label context** | Check for risk-relevant labels (e.g., `breaking-change`, `security`, `needs-discussion`) | No risk labels = 1, 1 advisory label = 2, 1 warning label = 3, 2+ warning labels or 1 critical label = 5 |
| **Acceptance criteria coverage** | Does the PR address all acceptance criteria in the issue? | All criteria met = 1, most met = 2, some met = 3, few met = 4, none met or no criteria = 5 |
| **Discussion history** | Count of unresolved threads in the linked issue | 0 = 1, 1-2 = 2, 3-5 = 3, 6-10 = 4, >10 = 5 |
| **Issue age and staleness** | Time since issue opened vs last activity. Compute: days_open = (now - created_at), days_stale = (now - last_activity). | Recent active (open <7d, stale <2d) = 1, moderate (open 7-30d, stale 2-7d) = 2, aging (open 31-90d, stale 8-30d) = 3, old (open 91-180d, stale 31-90d) = 4, stale (open >180d or stale >90d) = 5 |

**Procedure:** Evaluate each dimension, assign a 1-5 sub-score, then
average for the Tier 3 composite.

**Graceful degradation:** If issue context is unavailable or partial,
score only the available dimensions and average them. If no dimensions
can be scored, omit Tier 3 entirely and redistribute weights.

## Anchoring Examples

Use these examples to calibrate scoring across tiers.

| Scenario | Tier 1 | Tier 2 | Tier 3 | Composite | Level |
|----------|--------|--------|--------|-----------|-------|
| Typo fix in README, 1 file, 2 lines, no issue | 1.2 | 1.5 | N/A | **1** (0.62×1.2 + 0.38×1.5 ≈ 1.3 → 1) | low |
| Add logging to existing function, 3 files, 80 lines, issue with clear scope | 1.8 | 2.0 | 1.5 | **2** (0.50×1.8 + 0.30×2.0 + 0.20×1.5 = 1.8 → 2) | moderate |
| Refactor auth module, 12 files, 450 lines, high churn, issue scope matches | 3.2 | 3.8 | 2.0 | **3** (0.50×3.2 + 0.30×3.8 + 0.20×2.0 = 3.1 → 3) | elevated |
| New feature with CI changes, 25 files, 1200 lines, no issue | 4.0 | 3.5 | N/A | **4** (0.62×4.0 + 0.38×3.5 ≈ 3.8 → 4) | high |
| Dependency upgrade + protected path edits, 8 files, 300 lines, breaking-change label | 4.5 | 3.0 | 4.0 | **4** (0.50×4.5 + 0.30×3.0 + 0.20×4.0 = 3.9 → 4) | high |
| Security fix in crypto module, 2 files, 60 lines, urgent issue with unresolved threads | 3.0 | 4.5 | 4.5 | **4** (0.50×3.0 + 0.30×4.5 + 0.20×4.5 = 3.8 → 4) | high |

## Output Format

The sub-agent must return a JSON object with this schema:

```json
{
  "score": 3,
  "level": "elevated",
  "tier1_signals": [
    {"dimension": "FILES_CHANGED", "value": "12"},
    {"dimension": "LINES_CHANGED", "value": "450"},
    {"dimension": "BLAST_RADIUS", "value": "medium"}
  ],
  "tier2_signals": [
    {"dimension": "recent_commit_frequency_30d", "value": "8.5"},
    {"dimension": "distinct_authors_90d", "value": "3.2"}
  ],
  "tier3_signals": [
    {"dimension": "issue_scope_vs_pr_size", "value": "2"},
    {"dimension": "issue_labels", "value": "1"}
  ],
  "rationale": "Moderate file count and churn, auth module with high recent activity, issue scope aligns with PR size."
}
```

**Required fields:**
- `score` (integer 1-5)
- `level` (string: "low", "moderate", "elevated", "high", "critical")
- `rationale` (string: one-sentence summary of why this score was assigned)

**Optional fields:**
- `tier1_signals` (array of {dimension, value} objects)
- `tier2_signals` (array of {dimension, value} objects)
- `tier3_signals` (array of {dimension, value} objects)

The signal arrays enable graceful degradation: if a tier cannot be
fully evaluated, return partial signals or omit the array entirely.

**Output constraint:** Return raw JSON only — do not wrap in markdown
code fences (`` ```json ... ``` ``). The orchestrator parses the
response directly.

## Procedure

1. **Run Tier 1 script:**
   ```bash
   bash skills/pr-risk-assessment/scripts/risk-tier1.sh
   ```
   Capture KEY=VALUE output. Parse each line and store signals.

2. **Evaluate Tier 1 dimensions:**
   For each signal in the Tier 1 table, assign a 1-5 sub-score per the
   scoring guidance. Compute the average of all valid sub-scores (skip
   any `UNKNOWN` values). This is the Tier 1 composite score.

3. **Evaluate Tier 2 dimensions:**
   For each file in the PR's changed file list, run the git log
   commands from the Tier 2 table. Aggregate per-file results into
   dimension averages. Compute the average of the seven dimension
   sub-scores. This is the Tier 2 composite score.

4. **Evaluate Tier 3 dimensions (if issue linked):**
   If the PR links to an issue, evaluate each Tier 3 dimension per the
   criteria table. Compute the average of all valid sub-scores. This is
   the Tier 3 composite score. If no issue is linked, skip this step.

5. **Compute weighted composite:**
   - If Tier 3 is available: `score = 0.50×Tier1 + 0.30×Tier2 + 0.20×Tier3`
   - If Tier 3 is unavailable: `score = 0.62×Tier1 + 0.38×Tier2`
   Round to the nearest integer (1-5).

6. **Map score to level:**
   - 1 → "low"
   - 2 → "moderate"
   - 3 → "elevated"
   - 4 → "high"
   - 5 → "critical"

7. **Write rationale:**
   One sentence summarizing the key factors (file count, churn, labels,
   protected paths, etc.) that drove the score.

8. **Return JSON:**
   Construct the JSON object per the schema above. Return it as raw
   JSON (no markdown fences).
