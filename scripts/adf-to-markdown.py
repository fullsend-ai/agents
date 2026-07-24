#!/usr/bin/env python3
"""Convert Jira Atlassian Document Format (ADF) JSON to Markdown.

Usage:
    echo '{"type":"doc","version":1,"content":[...]}' | python3 adf-to-markdown.py
    jq '.fields.description' issue.json | python3 adf-to-markdown.py

Reads an ADF JSON object from stdin and writes clean Markdown to stdout.
Handles: headings, paragraphs, bold, italic, code, links, bullet/ordered lists,
tables, panels, code blocks, horizontal rules, hard breaks, expand nodes.

Counterpart to markdown-to-adf.py (used for the write path).
"""
import json
import sys

MAX_INPUT_BYTES = 256 * 1024
AGENT_MARKER_PREFIX = "fullsend:"


def render_marks(text: str, marks: list) -> str:
    """Wrap text with Markdown formatting based on ADF marks."""
    result = text
    link_href = None
    for mark in marks:
        mtype = mark.get("type", "")
        if mtype == "strong":
            result = f"**{result}**"
        elif mtype == "em":
            result = f"*{result}*"
        elif mtype == "code":
            result = f"`{result}`"
        elif mtype == "link":
            link_href = mark.get("attrs", {}).get("href", "")
    if link_href:
        result = f"[{result}]({link_href})"
    return result


def render_inline(nodes: list) -> str:
    """Render a list of ADF inline nodes to a Markdown string."""
    parts = []
    for node in nodes:
        ntype = node.get("type", "")
        if ntype == "text":
            text = node.get("text", "")
            marks = node.get("marks", [])
            parts.append(render_marks(text, marks))
        elif ntype == "hardBreak":
            parts.append("\n")
        elif ntype == "inlineCard":
            url = node.get("attrs", {}).get("url", "")
            if url:
                parts.append(f"[{url}]({url})")
        elif ntype == "emoji":
            parts.append(node.get("attrs", {}).get("text", ""))
        elif ntype == "mention":
            parts.append(f"@{node.get('attrs', {}).get('text', '')}")
        elif ntype == "status":
            parts.append(f"[{node.get('attrs', {}).get('text', '')}]")
    return "".join(parts)


def render_table(node: dict) -> str:
    """Render an ADF table node to a Markdown pipe table."""
    rows = node.get("content", [])
    if not rows:
        return ""

    md_rows = []
    for row in rows:
        cells = row.get("content", [])
        cell_texts = []
        for cell in cells:
            cell_content = cell.get("content", [])
            cell_text = render_blocks(cell_content).strip().replace("\n", " ")
            cell_texts.append(cell_text)
        md_rows.append("| " + " | ".join(cell_texts) + " |")

    if len(md_rows) >= 1:
        col_count = md_rows[0].count("|") - 1
        separator = "| " + " | ".join(["---"] * max(col_count, 1)) + " |"
        md_rows.insert(1, separator)

    return "\n".join(md_rows)


def render_list(node: dict, ordered: bool, indent: int = 0) -> str:
    """Render a bullet or ordered list, handling nesting."""
    items = node.get("content", [])
    lines = []
    prefix_space = "  " * indent

    for i, item in enumerate(items):
        if item.get("type") != "listItem":
            continue
        sub_content = item.get("content", [])
        first_block = True
        for block in sub_content:
            btype = block.get("type", "")
            if btype == "paragraph" and first_block:
                marker = f"{i + 1}." if ordered else "-"
                text = render_inline(block.get("content", []))
                lines.append(f"{prefix_space}{marker} {text}")
                first_block = False
            elif btype in ("bulletList", "orderedList"):
                nested = render_list(block, btype == "orderedList", indent + 1)
                lines.append(nested)
            elif btype == "paragraph":
                text = render_inline(block.get("content", []))
                lines.append(f"{prefix_space}  {text}")
            else:
                block_md = render_block(block, indent)
                if block_md:
                    lines.append(block_md)
                first_block = False

    return "\n".join(lines)


def render_block(node: dict, indent: int = 0) -> str:
    """Render a single ADF block node to Markdown."""
    ntype = node.get("type", "")

    if ntype == "heading":
        level = node.get("attrs", {}).get("level", 1)
        text = render_inline(node.get("content", []))
        return f"{'#' * level} {text}"

    if ntype == "paragraph":
        return render_inline(node.get("content", []))

    if ntype in ("bulletList", "orderedList"):
        return render_list(node, ntype == "orderedList", indent)

    if ntype == "table":
        return render_table(node)

    if ntype == "rule":
        return "---"

    if ntype == "codeBlock":
        lang = node.get("attrs", {}).get("language", "")
        code_text = render_inline(node.get("content", []))
        return f"```{lang}\n{code_text}\n```"

    if ntype == "blockquote":
        inner = render_blocks(node.get("content", []))
        return "\n".join(f"> {line}" if line else ">" for line in inner.split("\n"))

    if ntype == "panel":
        panel_type = node.get("attrs", {}).get("panelType", "info")
        inner = render_blocks(node.get("content", []))
        prefix = {"warning": "WARNING", "error": "ERROR", "success": "SUCCESS",
                   "note": "NOTE"}.get(panel_type, "NOTE")
        return "\n".join(f"> **{prefix}**: {line}" if i == 0 else f"> {line}"
                         for i, line in enumerate(inner.split("\n")))

    if ntype == "expand":
        title = node.get("attrs", {}).get("title", "")
        if not title or AGENT_MARKER_PREFIX in _expand_text(node):
            return ""
        if title.startswith("Previous"):
            return ""
        inner = render_blocks(node.get("content", []))
        return f"<details>\n<summary>{title}</summary>\n\n{inner}\n</details>"

    if ntype == "mediaSingle" or ntype == "media":
        return ""

    return ""


def _expand_text(node: dict) -> str:
    """Extract raw text from a node tree for marker detection."""
    if node.get("type") == "text":
        return node.get("text", "")
    parts = []
    for child in node.get("content", []):
        parts.append(_expand_text(child))
    return "".join(parts)


def render_blocks(nodes: list) -> str:
    """Render a list of ADF block nodes, joining with blank lines."""
    parts = []
    for node in nodes:
        rendered = render_block(node)
        if rendered is not None and rendered != "":
            parts.append(rendered)
    return "\n\n".join(parts)


def adf_to_markdown(adf: dict) -> str:
    """Convert a full ADF document to Markdown."""
    if not isinstance(adf, dict):
        return str(adf) if adf else ""

    if adf.get("type") == "doc":
        return render_blocks(adf.get("content", []))

    return render_blocks(adf.get("content", [adf]))


if __name__ == "__main__":
    raw = sys.stdin.read(MAX_INPUT_BYTES + 1)
    if len(raw) > MAX_INPUT_BYTES:
        print(f"ERROR: input exceeds {MAX_INPUT_BYTES} bytes", file=sys.stderr)
        sys.exit(1)

    raw = raw.strip()
    if not raw or raw in ('""', "null", '""'):
        sys.exit(0)

    if raw.startswith('"') and raw.endswith('"'):
        raw = json.loads(raw)
        if isinstance(raw, str):
            print(raw)
            sys.exit(0)

    try:
        adf = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"ERROR: invalid JSON: {e}", file=sys.stderr)
        sys.exit(1)

    print(adf_to_markdown(adf))
