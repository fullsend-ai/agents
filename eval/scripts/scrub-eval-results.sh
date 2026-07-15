#!/usr/bin/env bash
# scrub-eval-results.sh — Emulate GitHub Actions ::add-mask:: on eval artifacts.
#
# Production GHA runs process `::add-mask::<value>` in the job log so viewers
# see *** instead of the secret. The eval harness archives raw stdout into
# case logs *without* that runner processing, so the same line would leak
# EVAL_GH_TOKEN (and minted tokens) into upload-artifact.
#
# This script mirrors Actions behavior:
#   1. Collect every value from `::add-mask::<value>` across the tree
#   2. Replace those values with *** everywhere in text artifacts
#   3. Rewrite mask lines themselves to `::add-mask::***`
# Plus defense-in-depth redaction of common GitHub token shapes / git basic-auth
# URLs, and deletion of `.eval-env` dotenv files.
#
# Usage:
#   bash eval/scripts/scrub-eval-results.sh [dir ...]
# Defaults: eval/runs /tmp/agent-eval
set -euo pipefail

ROOTS=("$@")
if [[ ${#ROOTS[@]} -eq 0 ]]; then
  ROOTS=(eval/runs /tmp/agent-eval)
fi

export EVAL_SCRUB_ROOTS="${ROOTS[*]}"
python3 - <<'PY'
import os
import re
import sys
from pathlib import Path

ROOTS = [Path(p) for p in os.environ["EVAL_SCRUB_ROOTS"].split() if p]
TEXT_SUFFIXES = {".log", ".txt", ".json", ".jsonl", ".yaml", ".yml", ".md"}
ADD_MASK_RE = re.compile(r"::add-mask::(\S+)")
# Defense in depth — tokens that never went through ::add-mask::.
TOKEN_RES = [
    re.compile(r"\bghp_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bgho_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bghu_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bghs_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bghr_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"x-access-token:[^@/\s]+@"),
]

def iter_text_files(root: Path):
    if not root.is_dir():
        return
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if path.name == ".eval-env":
            try:
                path.unlink()
            except OSError:
                pass
            continue
        if path.suffix.lower() in TEXT_SUFFIXES:
            yield path

def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="surrogateescape")
    except OSError as e:
        print(f"WARNING: could not read {path}: {e}", file=sys.stderr)
        return None

# Pass 1: collect secrets registered via ::add-mask:: (Actions-compatible).
secrets: set[str] = set()
for root in ROOTS:
    for path in iter_text_files(root):
        text = read_text(path)
        if text is None:
            continue
        for match in ADD_MASK_RE.finditer(text):
            value = match.group(1)
            if value in ("***", "[REDACTED]", ""):
                continue
            secrets.add(value)

# Longest first so overlapping prefixes redact correctly.
ordered = sorted(secrets, key=len, reverse=True)

def redact(text: str) -> str:
    # Emulate Actions: mask line becomes ::add-mask::*** and the value is ***
    # wherever it appears (including earlier lines in the same file).
    for secret in ordered:
        if secret and secret in text:
            text = text.replace(secret, "***")
    text = ADD_MASK_RE.sub("::add-mask::***", text)
    for pat in TOKEN_RES:
        if pat.pattern.startswith("x-access-token:"):
            text = pat.sub("x-access-token:***@", text)
        else:
            # Keep a stable prefix hint without the secret material.
            text = pat.sub(lambda m: m.group(0).split("_", 1)[0] + "_***", text)
    return text

# Pass 2: rewrite files.
changed = 0
for root in ROOTS:
    for path in iter_text_files(root):
        text = read_text(path)
        if text is None:
            continue
        new = redact(text)
        if new != text:
            path.write_text(new, encoding="utf-8", errors="surrogateescape")
            changed += 1

# Fail closed: no live add-mask payloads or classic PAT shapes should remain.
leak_re = re.compile(
    r"::add-mask::(?!\*\*\*)(\S+)"
    r"|\bghp_[A-Za-z0-9_]{20,}"
    r"|\bgho_[A-Za-z0-9_]{20,}"
    r"|\bgithub_pat_[A-Za-z0-9_]{20,}"
)
leaks: list[str] = []
for root in ROOTS:
    for path in iter_text_files(root):
        text = read_text(path)
        if text is None:
            continue
        for m in leak_re.finditer(text):
            snippet = text[max(0, m.start() - 20) : m.end() + 20].replace("\n", "\\n")
            # Never print the secret itself in CI logs.
            snippet = re.sub(r"ghp_[A-Za-z0-9_]+", "ghp_***", snippet)
            snippet = re.sub(r"::add-mask::\S+", "::add-mask::***", snippet)
            leaks.append(f"{path}: ...{snippet}...")

if leaks:
    print("::error::Secrets remain in eval results after Actions-style scrub:", file=sys.stderr)
    for line in leaks[:50]:
        print(line, file=sys.stderr)
    sys.exit(1)

roots_disp = " ".join(str(r) for r in ROOTS)
print(
    f"Scrubbed eval results under: {roots_disp} "
    f"(add-mask secrets={len(ordered)}, files_rewritten={changed})"
)
PY
