#!/usr/bin/env python3
"""Convert markdown-style text to Jira Atlassian Document Format (ADF).

Usage:
    echo "## Heading\n\nSome **bold** text" | python3 markdown-to-adf.py
    python3 markdown-to-adf.py < comment.md
    python3 markdown-to-adf.py --wrap-detail < description.md

Outputs a JSON object suitable for the Jira REST API comment body field.

Flags:
  --wrap-detail  After conversion, collapse detail content into a Jira expand.
                 Split on a "Detailed Specification" heading if present,
                 otherwise on the first horizontal rule (---). Used for sticky
                 agent comments (meta above ---, detail below) and issue
                 descriptions.
  --no-expand    With --wrap-detail, use a heading fallback instead of expand
                 (Jira Data Center).
"""
import json
import re
import sys
from urllib.parse import urlparse

MAX_INPUT_BYTES = 128 * 1024
ALLOWED_SCHEMES = {"http", "https", "mailto", ""}


def strip_html_details(text: str) -> str:
    """Remove literal <details>/<summary> markers agents sometimes emit.

    Jira Cloud does not render HTML details; leaving the tags visible is noise.
    Content inside is preserved. A leading Detailed Specification summary becomes
    a markdown heading so --wrap-detail can collapse from there when needed.
    """
    # Normalize common agent patterns
    text = re.sub(
        r"<details>\s*<summary>\s*Detailed Specification\s*</summary>\s*",
        "\n\n## Detailed Specification\n\n",
        text,
        flags=re.I,
    )
    text = re.sub(r"</?details\s*>", "\n\n", text, flags=re.I)
    text = re.sub(r"<summary>\s*([^<]*?)\s*</summary>", r"\n\n## \1\n\n", text, flags=re.I)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text


def _jira_browse_base() -> str:
    """Browse base for auto-linking issue keys (trailing slash)."""
    import os

    explicit = os.environ.get("JIRA_BROWSE_BASE") or os.environ.get("JIRA_BROWSE") or ""
    if explicit:
        return explicit.rstrip("/") + "/"
    host = os.environ.get("JIRA_HOST") or ""
    if host:
        return f"https://{host}/browse/"
    return ""


def _append_plain_with_autolinks(nodes: list, plain: str) -> None:
    """Append plain text, auto-linking bare Jira keys when browse base is set."""
    if not plain:
        return
    base = _jira_browse_base()
    if not base:
        nodes.append({"type": "text", "text": plain})
        return
    key_re = re.compile(r"\b([A-Z][A-Z0-9]+-\d+)\b")
    pos = 0
    for m in key_re.finditer(plain):
        if m.start() > pos:
            nodes.append({"type": "text", "text": plain[pos : m.start()]})
        key = m.group(1)
        nodes.append(
            {
                "type": "text",
                "text": key,
                "marks": [{"type": "link", "attrs": {"href": f"{base}{key}"}}],
            }
        )
        pos = m.end()
    if pos < len(plain):
        nodes.append({"type": "text", "text": plain[pos:]})


def parse_inline(text: str) -> list:
    """Parse inline markdown (bold, code, links) into ADF inline nodes."""
    nodes = []
    pos = 0
    pattern = re.compile(
        r"(?P<bold>\*\*(.+?)\*\*)"
        r"|(?P<code>`([^`]+)`)"
        r"|(?P<link>\[([^\]]+)\]\(([^)]+)\))"
    )
    for m in pattern.finditer(text):
        if m.start() > pos:
            _append_plain_with_autolinks(nodes, text[pos : m.start()])
        if m.group("bold"):
            nodes.append(
                {
                    "type": "text",
                    "text": m.group(2),
                    "marks": [{"type": "strong"}],
                }
            )
        elif m.group("code"):
            nodes.append(
                {
                    "type": "text",
                    "text": m.group(4),
                    "marks": [{"type": "code"}],
                }
            )
        elif m.group("link"):
            href = m.group(7)
            scheme = urlparse(href).scheme.lower()
            if scheme in ALLOWED_SCHEMES:
                nodes.append(
                    {
                        "type": "text",
                        "text": m.group(6),
                        "marks": [{"type": "link", "attrs": {"href": href}}],
                    }
                )
            else:
                nodes.append({"type": "text", "text": f"{m.group(6)} ({href})"})
        pos = m.end()
    if pos < len(text):
        _append_plain_with_autolinks(nodes, text[pos:])
    if not nodes and text:
        _append_plain_with_autolinks(nodes, text)
    return nodes


def parse_inline_multiline(text: str) -> list:
    """Parse inline markdown, inserting hardBreak nodes for newlines."""
    lines = text.split("\n")
    nodes: list = []
    for i, line in enumerate(lines):
        if line:
            nodes.extend(parse_inline(line))
        if i < len(lines) - 1:
            nodes.append({"type": "hardBreak"})
    while nodes and nodes[-1].get("type") == "hardBreak":
        nodes.pop()
    return nodes if nodes else [{"type": "text", "text": " "}]


def _parse_table_lines(lines: list) -> tuple:
    """Parse markdown table lines; stop at the first non-table line.

    Returns (table_node_or_None, remaining_lines).
    """
    table_lines = []
    rest = []
    stopped = False
    for l in lines:
        if stopped:
            rest.append(l)
            continue
        if not l.strip():
            stopped = True
            continue
        if re.match(r"^\|[-\s|]+\|$", l.strip()):
            continue  # separator row
        if l.strip().startswith("|"):
            table_lines.append(l)
        else:
            stopped = True
            rest.append(l)
    if len(table_lines) < 1:
        return None, lines
    table_node = {"type": "table", "attrs": {"layout": "default"}, "content": []}
    for i, tl in enumerate(table_lines):
        cells = [c.strip() for c in tl.strip().strip("|").split("|")]
        cell_type = "tableHeader" if i == 0 else "tableCell"
        row = {"type": "tableRow", "content": []}
        for cell in cells:
            row["content"].append(
                {
                    "type": cell_type,
                    "content": [{"type": "paragraph", "content": parse_inline(cell)}],
                }
            )
        table_node["content"].append(row)
    return table_node, rest


def text_to_adf(text: str) -> dict:
    """Convert markdown-style text to an ADF document."""
    doc = {"type": "doc", "version": 1, "content": []}
    blocks = re.split(r"\n{2,}", text.strip())

    for block in blocks:
        block = block.strip()
        if not block:
            continue

        if block == "---":
            doc["content"].append({"type": "rule"})
            continue

        if all(re.match(r"^>\s?", line) for line in block.split("\n") if line.strip()):
            quote_text = "\n".join(
                re.sub(r"^>\s?", "", line) for line in block.split("\n")
            ).strip()
            panel_content = []
            for qline in quote_text.split("\n"):
                if qline.strip():
                    panel_content.append(
                        {
                            "type": "paragraph",
                            "content": parse_inline(qline.strip()),
                        }
                    )
            if panel_content:
                doc["content"].append(
                    {
                        "type": "panel",
                        "attrs": {"panelType": "info"},
                        "content": panel_content,
                    }
                )
            continue

        heading_match = re.match(r"^(#{1,6})\s+(.+)$", block)
        if heading_match and "\n" not in block:
            level = len(heading_match.group(1))
            doc["content"].append(
                {
                    "type": "heading",
                    "attrs": {"level": level},
                    "content": parse_inline(heading_match.group(2)),
                }
            )
            continue

        lines = block.split("\n")

        if all(re.match(r"^\s*[-*]\s+", line) for line in lines if line.strip()):
            list_node = {"type": "bulletList", "content": []}
            for line in lines:
                item_text = re.sub(r"^\s*[-*]\s+", "", line).strip()
                if item_text:
                    list_node["content"].append(
                        {
                            "type": "listItem",
                            "content": [
                                {"type": "paragraph", "content": parse_inline(item_text)}
                            ],
                        }
                    )
            if list_node["content"]:
                doc["content"].append(list_node)
            continue

        if all(re.match(r"^\s*\d+[.)]\s+", line) for line in lines if line.strip()):
            list_node = {"type": "orderedList", "content": []}
            for line in lines:
                item_text = re.sub(r"^\s*\d+[.)]\s+", "", line).strip()
                if item_text:
                    list_node["content"].append(
                        {
                            "type": "listItem",
                            "content": [
                                {"type": "paragraph", "content": parse_inline(item_text)}
                            ],
                        }
                    )
            if list_node["content"]:
                doc["content"].append(list_node)
            continue

        if re.match(r"^\|", block):
            table_node, rest = _parse_table_lines(lines)
            if table_node:
                doc["content"].append(table_node)
                # Re-process leftovers (heading/paragraph glued to table by missing blank line)
                if rest and any(l.strip() for l in rest):
                    leftover = "\n".join(rest).strip()
                    if leftover:
                        sub = text_to_adf(leftover)
                        doc["content"].extend(sub.get("content", []))
                continue

        mixed_content = []
        in_list = False
        list_type = "bulletList"
        list_items = []

        def _flush_list():
            nonlocal list_items, in_list, list_type
            if list_items:
                ln = {"type": list_type, "content": []}
                for it in list_items:
                    ln["content"].append(
                        {
                            "type": "listItem",
                            "content": [
                                {"type": "paragraph", "content": parse_inline(it)}
                            ],
                        }
                    )
                doc["content"].append(ln)
            list_items = []
            in_list = False
            list_type = "bulletList"

        for line in lines:
            is_bullet = bool(re.match(r"^\s*[-*]\s+", line))
            is_ordered = bool(re.match(r"^\s*\d+[.)]\s+", line))
            is_list_item = is_bullet or is_ordered
            is_heading = bool(re.match(r"^#{1,6}\s+", line))

            if is_list_item:
                new_type = "orderedList" if is_ordered else "bulletList"
                if in_list and new_type != list_type:
                    _flush_list()
                if not in_list and mixed_content:
                    para_text = "\n".join(mixed_content).strip()
                    if para_text:
                        doc["content"].append(
                            {
                                "type": "paragraph",
                                "content": parse_inline_multiline(para_text),
                            }
                        )
                    mixed_content = []
                in_list = True
                list_type = new_type
                if is_ordered:
                    item_text = re.sub(r"^\s*\d+[.)]\s+", "", line).strip()
                else:
                    item_text = re.sub(r"^\s*[-*]\s+", "", line).strip()
                list_items.append(item_text)
            elif is_heading:
                _flush_list()
                if mixed_content:
                    para_text = "\n".join(mixed_content).strip()
                    if para_text:
                        doc["content"].append(
                            {
                                "type": "paragraph",
                                "content": parse_inline_multiline(para_text),
                            }
                        )
                    mixed_content = []
                hm = re.match(r"^(#{1,6})\s+(.+)$", line)
                doc["content"].append(
                    {
                        "type": "heading",
                        "attrs": {"level": len(hm.group(1))},
                        "content": parse_inline(hm.group(2)),
                    }
                )
            else:
                _flush_list()
                if line.strip() == "---":
                    if mixed_content:
                        para_text = "\n".join(mixed_content).strip()
                        if para_text:
                            doc["content"].append(
                                {
                                    "type": "paragraph",
                                    "content": parse_inline_multiline(para_text),
                                }
                            )
                        mixed_content = []
                    doc["content"].append({"type": "rule"})
                else:
                    mixed_content.append(line)

        _flush_list()
        if mixed_content:
            para_text = "\n".join(mixed_content).strip()
            if para_text:
                doc["content"].append(
                    {
                        "type": "paragraph",
                        "content": parse_inline_multiline(para_text),
                    }
                )

    if not doc["content"]:
        doc["content"].append(
            {"type": "paragraph", "content": [{"type": "text", "text": text or " "}]}
        )

    return doc


def _is_generator_footer_node(node: dict) -> bool:
    """True for small trailing meta paragraphs from create-children."""
    if node.get("type") != "paragraph":
        return False
    texts = []
    for c in node.get("content") or []:
        if isinstance(c, dict) and c.get("type") == "text":
            texts.append(c.get("text") or "")
    blob = " ".join(texts).strip().lower()
    if not blob:
        return False
    return (
        "generated by fullsend" in blob
        or blob.startswith("priority:")
        or ("| scope:" in blob and "priority:" in blob)
    )


def wrap_detail_in_expand(doc: dict, use_expand: bool = True) -> dict:
    """Collapse detail content into a Jira expand.

    Used for sticky agent comments and issue descriptions (--wrap-detail).
    Split points (first match wins):
      1. Heading whose text is 'Detailed Specification'
      2. First horizontal rule node (meta table above, detail below)

    Generator footers (Priority/Scope/Generated by…) stay visible after the expand.
    """
    content = doc.get("content", [])

    split_idx = None
    consume_split_node = True
    for i, n in enumerate(content):
        if n.get("type") == "heading":
            title = "".join(
                c.get("text", "") for c in n.get("content", []) if isinstance(c, dict)
            ).strip()
            if title.lower() == "detailed specification":
                split_idx = i
                break
        if n.get("type") == "rule":
            split_idx = i
            break

    if split_idx is None:
        return doc

    visible = content[:split_idx]
    collapsed = content[split_idx + (1 if consume_split_node else 0) :]

    if not collapsed:
        doc["content"] = visible
        return doc

    if use_expand:
        footer: list = []
        while collapsed:
            node = collapsed[-1]
            if _is_generator_footer_node(node) or (
                node.get("type") == "rule" and footer
            ):
                footer.insert(0, collapsed.pop())
                continue
            break
        expand_node = {
            "type": "expand",
            "attrs": {"title": "Detailed Specification"},
            "content": collapsed,
        }
        doc["content"] = visible + ([expand_node] if collapsed else []) + footer
        return doc

    visible.append(
        {
            "type": "heading",
            "attrs": {"level": 2},
            "content": [
                {
                    "type": "text",
                    "text": "Detailed Specification",
                    "marks": [{"type": "strong"}],
                }
            ],
        }
    )
    visible.append({"type": "rule"})
    visible.extend(collapsed)
    doc["content"] = visible
    return doc


if __name__ == "__main__":
    raw = sys.stdin.read(MAX_INPUT_BYTES + 1)
    if len(raw) > MAX_INPUT_BYTES:
        print(f"ERROR: input exceeds {MAX_INPUT_BYTES} bytes", file=sys.stderr)
        sys.exit(1)

    wrap_detail = "--wrap-detail" in sys.argv
    use_expand = "--no-expand" not in sys.argv

    raw = strip_html_details(raw)
    adf = text_to_adf(raw)
    if wrap_detail:
        adf = wrap_detail_in_expand(adf, use_expand=use_expand)
    print(json.dumps({"body": adf}, ensure_ascii=False))
