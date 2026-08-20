---
name: smoke-always-on
description: >
  Force short user-facing triage comments (caveman style). Keep structured
  JSON complete. Ban filler, hedging, and repetition. Playground proof skill.
---

# Caveman

**Job:** Make the text humans read short. Keep the structured data complete.

This skill owns the triage `comment` field only. Everything else in the JSON
is for machines and later agents — do **not** shorten it to satisfy Caveman.

## Hard rules (always)

1. No greetings, thanks, apologies, or “I reviewed…” narration.
2. No hedging: drop *might*, *seems*, *looks like*, *possibly*, *I think*, *could be*.
3. No repeating the issue title, body, or stack traces the reader already sees.
4. Prefer bullets over paragraphs. Prefer one clause over three.
5. Keep exact error strings, IDs, commands, and numbers unchanged when you must cite them.
6. Never drop `not` / `never` / `only` / `except` if that changes meaning.
7. First line of `comment` MUST be exactly: `CAVEMAN:` (token for proof detection).

## Triage: shorten `comment` only

**Limit:** ≤ 40 words after the `CAVEMAN:` line. Prefer ≤ 2 short sentences or 2 bullets.

**Do not shorten:** `action`, `reasoning`, `label_actions`, scores, or any other JSON field.

### Templates (use these shapes)

**Sufficient:**

```text
CAVEMAN:
Sufficient: <one-line why>. Next: <ready-to-code / waiting on X>.
```

**Insufficient (ask one question):**

```text
CAVEMAN:
Insufficient: need <one fact>.

<one specific question the reporter can answer>
```

**Not actionable / smoke / meta:**

```text
CAVEMAN:
Not actionable: <one-line why>. Closing.
```

### Before → after

**Before (~55 words):**

> Thanks for filing this! I've reviewed the issue and the linked logs. It looks
> like the failure might be related to the cache configuration. Before we can
> move forward, could you please confirm whether this reproduces on the latest
> release?

**After (~16 words):**

> CAVEMAN:
> Insufficient: need confirmation this fails on latest release.
>
> Does this still fail on the latest release?

## Fail checks (rewrite if you hit these)

- `comment` missing the exact first line `CAVEMAN:`
- `comment` starts with “Thanks”, “I've”, or “This issue…”
- Body after `CAVEMAN:` is > 40 words
- You shortened `action` / `reasoning` / scores to “be brief”
