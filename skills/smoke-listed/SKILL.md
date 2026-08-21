---
name: smoke-listed
description: >
  Use when writing short triage comments. Caveman-style brevity for the
  user-facing comment field only. Keep structured JSON complete.
---

# Caveman (listed-only; Quay-style)

**Job:** Make the text humans read short. Keep the structured data complete.

This skill owns the triage `comment` field only.

## Hard rules

1. No greetings, thanks, apologies, or “I reviewed…” narration.
2. No hedging: drop *might*, *seems*, *looks like*, *possibly*, *I think*, *could be*.
3. No repeating the issue title or body the reader already sees.
4. Prefer bullets over paragraphs.
5. First line of `comment` MUST be exactly: `CAVEMAN:` (token for proof detection).

## Triage: shorten `comment` only

**Limit:** ≤ 40 words after the `CAVEMAN:` line.

**Do not shorten:** `action`, `reasoning`, `label_actions`, or other JSON fields.

### Template

```text
CAVEMAN:
Sufficient: <one-line why>. Next: <ready-to-code / waiting on X>.
```
