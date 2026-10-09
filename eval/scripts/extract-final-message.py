#!/usr/bin/env python3
"""Print the agent's final assistant message from a fullsend run directory.

Usage: extract-final-message.py <fs-cod-* dir>

Looks at the last iteration's output.jsonl and understands the three runtime
transcript shapes fullsend writes:
  Claude Code  {"type":"assistant","message":{"content":[{"type":"text",...}]}}
  pi           {"type":"message_end","message":{"role":"assistant","content":[...]}}
  codex        {"type":"item.completed","item":{"type":"agent_message","text":...}}
Prints the text (empty if none found); exit 0 either way.
"""
import json
import sys
from pathlib import Path


def iterations(run_dir: Path):
    return sorted(run_dir.glob("iteration-*/output.jsonl"),
                  key=lambda p: int(p.parent.name.split("-")[-1]))


def texts_from_content(content):
    if isinstance(content, str):
        return [content]
    return [c.get("text", "") for c in content or [] if isinstance(c, dict) and c.get("type") == "text"]


def final_message(path: Path) -> str:
    last = ""
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = ev.get("type")
            text = ""
            if t == "assistant":  # Claude Code
                text = "\n".join(texts_from_content((ev.get("message") or {}).get("content")))
            elif t == "message_end":  # pi
                msg = ev.get("message") or {}
                if msg.get("role") == "assistant":
                    text = "\n".join(texts_from_content(msg.get("content")))
            elif t == "item.completed":  # codex
                item = ev.get("item") or {}
                if item.get("type") == "agent_message":
                    text = item.get("text", "")
            if text and text.strip():
                last = text.strip()
    return last


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    run_dir = Path(sys.argv[1])
    its = iterations(run_dir)
    if not its:
        return 0
    print(final_message(its[-1]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
