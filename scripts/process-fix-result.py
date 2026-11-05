#!/usr/bin/env python3
"""Process fix-result.json and post a summary comment on the PR.

Reads the structured output from the fix agent and posts a summary comment
documenting what was fixed and what was disagreed with. When the agent
proposed a replacement PR/MR title or body (pr_title / pr_body), applies it
after schema validation and the post-script's secret scan have passed.
Metadata-update problems are reported as warnings and in the summary
comment; they never change the exit code.

Usage:
    process-fix-result.py <fix-result.json> <owner/repo> <pr-number> [--dry-run]

Environment:
    FIX_RESULT_SECRET_SCAN — set to "passed" by post-fix.sh only when its
                             gitleaks scan of the result file ran and passed;
                             any other value blocks the metadata update.

Exit codes:
    0 — summary posted (or dry-run completed)
    1 — invalid arguments or unreadable input file
    2 — failed to post summary comment (push may have already succeeded)
"""

import hashlib
import json
import os
import re
import subprocess
import sys

try:
    import jsonschema
except ImportError:
    jsonschema = None


def build_summary_body(data):
    """Build the markdown summary comment body."""
    summary = data.get("summary", "Fix agent completed.")
    decision_points = data.get("decision_points", [])
    tests_passed = data.get("tests_passed", False)
    trigger = data.get("trigger_source", "unknown")
    iteration = data.get("iteration", 1)
    actions = data.get("actions", [])

    fixed = [a for a in actions if a.get("type") == "fix"]
    disagreed = [a for a in actions if a.get("type") == "disagree"]

    fixes_text = ""
    if fixed:
        items = []
        for i, a in enumerate(fixed, 1):
            finding = a.get("finding", "unknown")
            desc = a.get("description", "")
            path = a.get("path", "")
            path_suffix = f" (`{path}`)" if path else ""
            items.append(f"{i}. **{finding}**{path_suffix}: {desc}")
        fixes_text = "\n".join(items)

    disagree_text = ""
    if disagreed:
        items = []
        for i, a in enumerate(disagreed, 1):
            finding = a.get("finding", "unknown")
            reason = a.get("reason", "No reason provided.")
            items.append(f"{i}. **{finding}**: {reason}")
        disagree_text = "\n".join(items)

    dp_text = ""
    if decision_points:
        dp_items = []
        for dp in decision_points:
            desc = dp.get("description", "")
            rationale = dp.get("rationale", "")
            alts = dp.get("alternatives", [])
            alt_text = ", ".join(alts) if alts else "none considered"
            dp_items.append(f"- {desc} (alternatives: {alt_text}; rationale: {rationale})")
        dp_text = (
            "\n<details>\n<summary>Decision points</summary>\n\n"
            + "\n".join(dp_items)
            + "\n</details>\n"
        )

    tests_str = "passed" if tests_passed else "**failed**"

    sections = [f"### \U0001f527 Fix agent — iteration {iteration} ({trigger}-triggered)\n"]
    sections.append(f"{summary}\n")

    if fixes_text:
        sections.append(f"**Fixed ({len(fixed)}):**\n{fixes_text}\n")

    if disagree_text:
        sections.append(f"**Disagreed ({len(disagreed)}):**\n{disagree_text}\n")

    sections.append(f"**Tests:** {tests_str}")

    ci_inspections = data.get("ci_inspections") or []
    if ci_inspections:
        items = []
        for i, job in enumerate(ci_inspections, 1):
            name = job.get("job", "unknown")
            status = job.get("status", "")
            classification = job.get("classification", "")
            diagnosis = job.get("diagnosis", "")
            remediation = job.get("remediation", "")
            status_bit = f", `{status}`" if status else ""
            line = f"{i}. **{name}** ({classification}{status_bit})"
            details = []
            if diagnosis:
                details.append(diagnosis)
            if remediation:
                details.append(remediation)
            if details:
                line += ": " + " ".join(details)
            items.append(line)
        sections.append(
            f"\n**CI inspections ({len(ci_inspections)}):**\n" + "\n".join(items)
        )

    conflict_update = data.get("conflict_update") or {}
    if conflict_update:
        parts = []
        outcome = conflict_update.get("outcome", "")
        strategy = conflict_update.get("strategy", "")
        forge_state = conflict_update.get("forge_state", "")
        target_branch = conflict_update.get("target_branch", "")
        target_sha = conflict_update.get("target_sha", "")
        if outcome:
            parts.append(outcome)
        if strategy:
            parts.append(f"strategy `{strategy}`")
        if forge_state:
            parts.append(f"forge `{forge_state}`")
        if target_branch:
            sha_bit = f"@{target_sha}" if target_sha else ""
            parts.append(f"target `{target_branch}{sha_bit}`")
        if parts:
            sections.append("\n**Conflict update:** " + "; ".join(parts))

    strategy_change = data.get("strategy_change", "")
    if strategy_change:
        sections.append(f"\n> **Strategy change:** {strategy_change}")

    if dp_text:
        sections.append(dp_text)

    return "\n".join(sections)


# GitHub API limit is 65536 chars; buffer for byte/char encoding discrepancies
MAX_COMMENT_LENGTH = 62000

FOOTER = (
    "\n---\n"
    "**Next steps:**\n"
    "- `/fs-review` — request a re-review of the changes\n"
    "- `/fs-fix <your instruction>` — run another fix pass with specific guidance\n"
    "- Push commits directly — review re-runs automatically on push"
)

ATTRIBUTION = (
    '\n<sub>Updated by <a href="https://github.com/fullsend-ai/fullsend">'
    "fullsend</a> fix agent</sub>"
)


def _post_comment_github(repo, pr_number, full):
    """Post a comment via the GitHub CLI."""
    subprocess.run(
        ["gh", "pr", "comment", str(pr_number), "--repo", repo, "--body-file", "-"],
        input=full,
        check=True,
        capture_output=True,
        text=True,
    )


def _get_allowed_gitlab_hosts():
    """Build the allowed host set from CI_SERVER_HOST."""
    ci_host = os.environ.get("CI_SERVER_HOST", "")
    if not ci_host:
        return set()
    if not re.fullmatch(r"[a-zA-Z0-9._-]+", ci_host):
        raise ValueError("CI_SERVER_HOST contains invalid characters")
    return {ci_host.lower()}


def _gitlab_host_and_token():
    """Resolve and validate the GitLab API host and token from the environment."""
    from urllib.parse import urlparse

    gitlab_host = os.environ.get("GITLAB_HOST", "")
    gitlab_token = os.environ.get("GITLAB_TOKEN", "")
    if not gitlab_host:
        pr_url = os.environ.get("PR_URL", "")
        if pr_url:
            parsed = urlparse(pr_url)
            gitlab_host = parsed.hostname or ""
        if not gitlab_host:
            raise ValueError("GITLAB_HOST is not set and cannot be derived from PR_URL")
    allowed_hosts = _get_allowed_gitlab_hosts()
    if not allowed_hosts:
        raise ValueError(
            "No trusted GitLab host configured (CI_SERVER_HOST is not set)"
        )
    if gitlab_host.lower() not in allowed_hosts:
        raise ValueError(
            f"GITLAB_HOST '{gitlab_host}' is not in the allowed host list"
        )
    if not gitlab_token:
        raise ValueError("GITLAB_TOKEN is not set")
    return gitlab_host, gitlab_token


def _gitlab_mr_request(repo, pr_number, method, suffix="", fields=()):
    """Call the GitLab merge request API; return the CompletedProcess."""
    from urllib.parse import quote

    gitlab_host, gitlab_token = _gitlab_host_and_token()
    repo_encoded = quote(repo, safe="")
    api_url = (
        f"https://{gitlab_host}/api/v4"
        f"/projects/{repo_encoded}/merge_requests/{pr_number}{suffix}"
    )
    data_args = []
    for name, value in fields:
        data_args += ["--data-urlencode", f"{name}={value}"]
    # Pass token via curl config on stdin so it never appears in
    # CalledProcessError.cmd tracebacks.
    config_stdin = f'header = "PRIVATE-TOKEN: {gitlab_token}"'
    return subprocess.run(
        [
            "curl",
            "--fail",
            "--silent",
            "--show-error",
            "--connect-timeout",
            "10",
            "--max-time",
            "30",
            "--config",
            "-",
            "--request",
            method,
            *data_args,
            api_url,
        ],
        input=config_stdin,
        check=True,
        capture_output=True,
        text=True,
    )


def _post_comment_gitlab(repo, pr_number, full):
    """Post a comment via the GitLab REST API."""
    _gitlab_mr_request(repo, pr_number, "POST", "/notes", [("body", full)])


def post_summary(repo, pr_number, body, suffix="", dry_run=False):
    """Post a summary comment on the PR."""
    forge = os.environ.get("FULLSEND_FORGE", "github")
    full = body + suffix
    if len(full) > MAX_COMMENT_LENGTH:
        truncation_notice = "\n\n*[truncated — output exceeded comment size limit]*"
        original_len = len(full)
        budget = MAX_COMMENT_LENGTH - len(suffix) - len(truncation_notice)
        full = body[:budget] + truncation_notice + suffix
        print(
            f"::warning::Comment body truncated from {original_len} to {MAX_COMMENT_LENGTH} chars"
        )
    if dry_run:
        print(f"  [dry-run] Would post PR summary ({len(full)} chars)")
        return True
    try:
        if forge == "gitlab":
            _post_comment_gitlab(repo, pr_number, full)
        else:
            _post_comment_github(repo, pr_number, full)
        return True
    except subprocess.CalledProcessError as e:
        sanitized = e.stderr.replace("\r", "").replace("\n", " ").replace("::", ": :")
        print(
            f"::warning::Failed to post PR summary: {sanitized}",
            file=sys.stderr,
        )
        return False
    except ValueError as e:
        print(
            f"::warning::Failed to post PR summary: {e}",
            file=sys.stderr,
        )
        return False


# ---------------------------------------------------------------------------
# PR/MR metadata update (pr_title / pr_body)
# ---------------------------------------------------------------------------

# post-code.sh ends every PR body it creates with "---", the issue reference,
# and this heading. The block is post-script-owned and survives a body update.
VERIFICATION_HEADING = "### Post-script verification"

# Forge closing keywords plus the non-closing "Related to" that post-code.sh
# writes, followed by an issue reference (#N, owner/repo#N, GH-N, or a URL).
# GitLab's -ing forms (closing, fixing, resolving, implementing) are included.
_REF_KEYWORD = (
    r"(?:close[sd]?|closing|fix(?:e[sd]|ing)?|resolv(?:e[sd]?|ing)"
    r"|implement(?:s|ed|ing)?|related\s+to)"
)
_REF_TARGET = r"(?:\S*#\d+|GH-\d+|https?://\S+)"
# The keyword may be followed by "issue"/"issues" before the target.
_REF_SEP = r"[\s:*_`]*(?:issues?\b[\s:*_`]*)?"
_REF_BODY = rf"{_REF_KEYWORD}\b{_REF_SEP}{_REF_TARGET}"

# A reference at the start of a line, optionally behind a list marker.
ISSUE_REF_RE = re.compile(rf"^\s*(?:[-*+]\s+)?{_REF_BODY}", re.IGNORECASE)

# _mask_code replaces every character of masked code with this placeholder
# (newlines are kept). It is not whitespace, so a reference match cannot span it.
_MASK_CHAR = "\x00"
_EXISTING_TARGET = r"(?:[^\s\x00]*#\d+|GH-\d+|https?://[^\s\x00]+)"
_EXISTING_TARGET_LIST = rf"{_EXISTING_TARGET}(?:\s*(?:,|\band\b)\s*{_EXISTING_TARGET})*"

# A reference anywhere in the text, as forges recognize them in prose and lists;
# a reference at the start of a line keeps its list marker. Used to carry
# existing references over from text that went through _mask_code; the match
# may span lines but never masked code.
_EXISTING_REF_RE = re.compile(
    rf"(?P<ref>(?:^[ \t]*[-*+][ \t]+|\b){_REF_KEYWORD}\b{_REF_SEP}{_EXISTING_TARGET_LIST})",
    re.IGNORECASE | re.MULTILINE,
)

# A line that holds nothing but closing references (optionally behind a list
# marker), for text that went through _mask_live_text: a target never contains
# masked text, and any prose after the references means the line is not only a
# reference.
_LIVE_ISSUE_REF_RE = re.compile(
    rf"^\s*(?:[-*+]\s+)?{_REF_KEYWORD}\b{_REF_SEP}{_EXISTING_TARGET_LIST}[\s.;]*$", re.IGNORECASE
)
_LIVE_REF_ANYWHERE_RE = re.compile(
    rf"\b(?P<ref>{_REF_KEYWORD}\b{_REF_SEP}(?P<target>{_EXISTING_TARGET_LIST}))", re.IGNORECASE
)

# An ATX "### Post-script verification" heading in any rendering-equivalent
# form: up to three leading spaces, optional closing hashes.
_VERIFICATION_HEADING_RE = re.compile(
    rf"^ {{0,3}}###[ \t]+{re.escape(VERIFICATION_HEADING[4:])}[ \t]*(?:#+[ \t]*)?$"
)


# Markdown code that forges do not treat as live text. Block code (fenced and
# indented) is found by a line-aware pass that follows list containers and
# CommonMark tab stops; inline code spans are a backtick run closed by a run of
# equal length within one paragraph.
_BACKTICK_RUN_RE = re.compile(r"`+")
_BLANK_LINE_RE = re.compile(r"\n[ \t]*\n")
# As in CommonMark, the info string of a backtick fence cannot contain a backtick.
_FENCE_OPEN_RE = re.compile(r"^ {0,3}(?P<fence>`{3,}|~{3,})(?P<info>.*)$")
_LIST_MARKER_RE = re.compile(r"^ {0,3}(?P<marker>[-*+]|\d{1,9}[.)])(?P<gap>[ \t]+|$)")
_THEMATIC_BREAK_RE = re.compile(r"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$")
_ATX_HEADING_RE = re.compile(r"^ {0,3}#{1,6}(?:[ \t]|$)")
# A setext underline; only a heading underline when it follows paragraph text.
_SETEXT_UNDERLINE_RE = re.compile(r"^ {0,3}(?:=+|-+)[ \t]*$")
_BLOCKQUOTE_PREFIX_RE = re.compile(r"^ {0,3}>[ ]?")
# An HTML comment runs to its closing "-->" or, when unclosed, to the end of
# the text. Applied after code is masked, so "<!--" in code is not a comment.
_HTML_COMMENT_RE = re.compile(r"<!--.*?(?:-->|\Z)", re.DOTALL)
# The line that opens a raw HTML block that runs to an explicit end condition
# rather than to a blank line (CommonMark HTML block types 1, 3, 4 and 5), after
# its blockquote and list prefixes are consumed. Its content is literal, not
# live text, and it can interrupt a paragraph. One that is never closed absorbs
# everything to the end of its container (or the text).
_RAW_HTML_START_RE = re.compile(
    r"^(?P<prefix>(?:[ \t]*>|[ \t]*(?:[-*+]|\d{1,9}[.)])(?=[ \t]))*[ \t]{0,3})"
    r"<(?:(?P<raw>(?:pre|script|style|textarea)(?=[\s>]|$))|(?P<pi>\?)"
    r"|(?P<cdata>!\[CDATA\[)|(?P<decl>![A-Za-z]))",
    re.IGNORECASE,
)
_RAW_HTML_CLOSE_RE = {
    "raw": re.compile(r"</(?:pre|script|style|textarea)>", re.IGNORECASE),
    "pi": re.compile(r"\?>"),
    "cdata": re.compile(r"\]\]>"),
    "decl": re.compile(r">"),
}
_RAW_HTML_CONTAINER_RE = re.compile(
    r"(?P<indent>[ \t]*)(?:(?P<quote>>[ ]?)|(?P<marker>[-*+]|\d{1,9}[.)])(?P<gap>[ \t]+))"
)


def _raw_html_containers(prefix):
    """Return the containers a raw HTML opener sits in behind prefix, outermost
    first: "q" for a blockquote, or the content offset of a list item."""
    containers = []
    for m in _RAW_HTML_CONTAINER_RE.finditer(prefix):
        if m.group("quote"):
            containers.append("q")
        else:
            gap = len(m.group("gap"))
            width = gap if 1 <= gap <= 4 else 1
            containers.append(len(m.group("indent")) + len(m.group("marker")) + width)
    return containers


def _raw_html_content(line, containers):
    """Return line without the prefixes of the containers of an open raw HTML
    block, or None when the line is outside them and so ends the block.

    A blockquote needs its ">" prefix, so a blank or unmarked line ends it; a
    list item takes blank lines and lines indented to its content.
    """
    rest = _expand_indent(line)
    for container in containers:
        if container == "q":
            m = _BLOCKQUOTE_PREFIX_RE.match(rest)
            if not m:
                return None
            rest = _expand_indent(rest[m.end() :])
        elif rest.strip():
            if len(rest) - len(rest.lstrip(" ")) < container:
                return None
            rest = rest[container:]
    return rest


def _normalize_newlines(text):
    return text.replace("\r\n", "\n").replace("\r", "\n")


def _expand_indent(line):
    """Expand the leading whitespace of line to spaces using 4-column tab stops."""
    col = 0
    i = 0
    while i < len(line) and line[i] in " \t":
        col += 1 if line[i] == " " else 4 - col % 4
        i += 1
    return " " * col + line[i:]


def _mask_block_code(text, mask_raw_html=False):
    """Mask fenced and indented code blocks, line by line.

    Newlines are kept and line endings are normalized to "\\n", so line i of the
    result is line i of the normalized text. Tracks list items so a fence or
    code block inside one is recognized at the item's content indent, expands
    tabs to 4-column stops, and lets indented code start at the beginning of
    the text or after any non-paragraph block (blank line, heading, thematic
    break, setext heading underline, fenced code); it cannot interrupt a
    paragraph. A "> " blockquote prefix is stripped and the quoted text is
    scanned on its own; list state restarts whenever the quote depth changes.
    An open fence records the quote depth it opened at and consumes only that
    many prefixes, so a ">" inside fence content stays content. A fence left
    open runs to the end of its container (or the text). HTML comments are
    masked in the same pass, outside code only: a fence marker inside a comment
    does not open a block, and a comment marker inside code stays literal. A raw
    HTML block (<pre>, <script>, ... see _RAW_HTML_START_RE) is tracked the same
    way as a fence: it records its quote depth and content column, runs to its
    end condition or the end of its container, and its content cannot open a
    fence, comment or list item. Its lines are masked only when mask_raw_html is
    set, so callers that must not trust the parse can still see their text.
    """
    lines = _normalize_newlines(text).split("\n")
    # Inline code spans can cross lines within a paragraph, so a "<!--" is
    # looked for on lines whose code spans were found over the whole text.
    shown = _mask_inline_code("\n".join(lines)).split("\n")
    out = list(lines)
    stack = []  # content columns of the open list items
    fence = None  # (closing-fence regex, content column, blockquote depth)
    raw = None  # (type of the open raw HTML block, its containers)
    para = False  # previous line was paragraph text
    qdepth = 0  # blockquote depth of the previous line
    comment = False  # inside an HTML comment that began on an earlier line
    for i, line in enumerate(lines):
        if comment:
            # Comment text is raw HTML: a fence or list marker in it does not
            # change the block state, so only the closing "-->" is looked for.
            out[i], comment = _mask_html_comments(line, shown[i], True)
            if not comment:
                para = bool(out[i].replace(_MASK_CHAR, "").strip())
            continue
        e = _expand_indent(line)
        if fence is not None:
            # An active fence is resolved first: only the quote prefixes of its own
            # container are consumed, so a further ">" is fence content and cannot
            # change the quote, list, paragraph or fence state.
            close_re, base, fdepth = fence
            fe = e
            for _ in range(fdepth):
                m = _BLOCKQUOTE_PREFIX_RE.match(fe)
                if not m:
                    break
                fe = fe[m.end():]
            else:
                if not fe.strip(" "):
                    continue
                if len(fe) - len(fe.lstrip(" ")) >= base:
                    out[i] = _MASK_CHAR * len(line)
                    if close_re.match(fe[base:]):
                        fence = None
                        para = False
                    continue
            fence = None  # the container ended, and the unclosed fence with it
        if raw is not None:
            # Like a fence, an open raw HTML block is resolved first: its content
            # is literal, so only its own containers' prefixes are consumed and
            # a blank line, list marker or fence inside it changes nothing.
            raw_kind, containers = raw
            content = _raw_html_content(line, containers)
            if content is not None:
                if mask_raw_html:
                    out[i] = _MASK_CHAR * len(line)
                if _RAW_HTML_CLOSE_RE[raw_kind].search(content):
                    raw = None
                    para = False
                continue
            raw = None  # the container ended, and the unclosed block with it
        depth = 0
        while True:
            m = _BLOCKQUOTE_PREFIX_RE.match(e)
            if not m:
                break
            depth += 1
            e = e[m.end():]
        if depth != qdepth:
            stack, para, qdepth = [], False, depth
        if not e.strip(" "):
            para = False
            continue
        indent = len(e) - len(e.lstrip(" "))
        closed_item = False
        while stack and indent < stack[-1]:
            stack.pop()
            closed_item = True
        pos = stack[-1] if stack else 0
        kind = "text"
        # Paragraph text this line could interrupt: none when it leaves the item
        # holding the paragraph, and none right after a list marker on the line.
        in_para = para and not closed_item
        while True:
            rest = e[pos:]
            if len(rest) - len(rest.lstrip(" ")) >= 4:
                kind = "text" if para else "code"
                break
            if para and _SETEXT_UNDERLINE_RE.match(rest):
                kind = "block"  # ends the heading, so indented code may follow
                break
            if _THEMATIC_BREAK_RE.match(rest):
                kind = "block"
                break
            m = _LIST_MARKER_RE.match(rest)
            if m and in_para and not _list_item_interrupts(m):
                break  # e.g. "2. x" inside a paragraph is paragraph text
            if m:
                in_para = False
                col = pos + m.end("marker")
                gap = 0
                for c in m.group("gap"):
                    gap += 1 if c == " " else 4 - (col + gap) % 4
                after = rest[m.end():]
                e = e[:col] + " " * gap + after
                pos = col + (gap if 1 <= gap <= 4 and after.strip() else 1)
                stack.append(pos)
                if not after.strip():
                    kind = "block"
                    break
                continue
            m = _FENCE_OPEN_RE.match(rest)
            if m and not (m.group("fence")[0] == "`" and "`" in m.group("info")):
                char = re.escape(m.group("fence")[0])
                close_re = re.compile(rf"^ {{0,3}}{char}{{{len(m.group('fence'))},}}[ \t]*$")
                fence = (close_re, pos, depth)
                kind = "code"
                break
            m = _RAW_HTML_START_RE.match(rest)
            if m:
                raw_kind = next(name for name in _RAW_HTML_CLOSE_RE if m.group(name) is not None)
                # The end condition is looked for past the "<" that opens the block.
                if not _RAW_HTML_CLOSE_RE[raw_kind].search(rest, m.end("prefix") + 1):
                    # The block sits in the enclosing quotes and list item, and
                    # in any containers opened on its own line.
                    containers = ["q"] * depth + ([pos] if pos else [])
                    raw = (raw_kind, containers + _raw_html_containers(m.group("prefix")))
                kind = "raw"
                break
            if _ATX_HEADING_RE.match(rest):
                kind = "block"
            break
        if kind == "code" or (kind == "raw" and mask_raw_html):
            out[i] = _MASK_CHAR * len(line)
        elif kind != "raw":
            out[i], comment = _mask_html_comments(line, shown[i], False)
        para = kind == "text"
    return "\n".join(out)


_CONTAINER_PREFIX_RE = re.compile(
    r"^(?:[ \t]*>|[ \t]*(?:[-*+]|\d{1,9}[.)])(?=[ \t]))*[ \t]*"
)
# A line that starts an HTML block (a comment, tag, processing instruction or
# declaration). Such a block can interrupt a paragraph.
_HTML_BLOCK_START_RE = re.compile(r"^<(?:!--|[A-Za-z/?!])")
# The HTML block types (CommonMark 4.6, types 1-6) that can interrupt a
# paragraph. Type 7, any other tag alone on a line, cannot: inside a paragraph
# it is inline HTML.
_HTML_BLOCK_NAMES = (
    "address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|"
    "details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|"
    "h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|"
    "optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|"
    "tr|track|ul"
)
_HTML_INTERRUPT_RE = re.compile(
    r"^<(?:"
    r"(?:pre|script|style|textarea)(?=[\s>]|$)"
    r"|!--|\?|![A-Za-z]|!\[CDATA\["
    rf"|/?(?:{_HTML_BLOCK_NAMES})(?=[\s>]|/>|$)"
    r")",
    re.IGNORECASE,
)


def _paragraph_starts(lines):
    """Return the indexes of lines that begin a new inline-code segment.

    A code span never crosses a block boundary, so spans are matched within a
    segment only. The check is deliberately conservative: anything that could
    interrupt a paragraph (an ATX heading, thematic break, setext underline,
    fence, list item, new blockquote or HTML block) splits the text, and a
    single-line block also splits what follows it. Splitting too little would
    let a span hide a real comment opener, and splitting too much can end a
    real span early and expose text that is code, so a list item splits only
    where it can start a block (see _list_item_interrupts). Leading blockquote
    and list markers are skipped so a block inside a container is still seen.
    """
    starts = {0}
    prev_quote = False
    prev_para = False
    # Content offsets of the open list items, outermost first: a line indented
    # less than the innermost one is outside that item.
    items = []
    prev_blank = False
    qdepth = 0
    for i, line in enumerate(lines):
        if not line.strip():
            prev_blank = True
            prev_para = False
            prev_quote = False
            continue
        # The line inside its blockquote container(s): list markers and the
        # indent that continues a list item are looked for here, not on the
        # raw line, where a "> " prefix would hide them.
        inner = _expand_indent(line)
        depth = 0
        while True:
            m = _BLOCKQUOTE_PREFIX_RE.match(inner)
            if not m:
                break
            depth += 1
            inner = inner[m.end() :]
        if depth != qdepth:
            items = []  # list state restarts whenever the quote depth changes
            if depth > qdepth:
                # A nested blockquote is a new container: a span cannot open in
                # the outer one and close inside it, so it starts a segment.
                starts.add(i)
                prev_para = False
            qdepth = depth
        if not inner.strip():
            # A line holding only blockquote prefixes is blank inside its
            # container, so it ends the quoted paragraph like a blank line, and
            # a code span cannot cross it, whether or not the next paragraph is
            # still inside the quote.
            starts.add(i)
            prev_blank = True
            prev_para = False
            prev_quote = False
            continue
        unindented = not inner[:1].isspace()
        marker = _LIST_MARKER_RE.match(inner)
        if items and unindented and (prev_blank and not marker or _ATX_HEADING_RE.match(inner)):
            # An unindented paragraph after a blank line, or an unindented
            # heading, ends the list.
            items = []
        prev_blank = False
        item_text = False
        content = _CONTAINER_PREFIX_RE.sub("", line)
        if marker:
            indent = len(inner) - len(inner.lstrip(" "))
            # A marker outside the innermost open item (indented less than its
            # content) is never inside a paragraph, so it always starts an item;
            # inside an item's content the paragraph-interruption rule applies.
            outside = bool(items) and indent < items[-1]
            if outside or not prev_para or _list_item_interrupts(marker):
                while items and items[-1] > indent:
                    items.pop()
                gap = marker.group("gap")
                width = len(gap) if 1 <= len(gap) <= 4 and gap.strip() == "" else 1
                items.append(indent + len(marker.group("marker")) + width)
                item_text = bool(inner[marker.end() :].strip())
            else:
                # Plain paragraph text, e.g. "2. x" after a paragraph line: what
                # follows the marker is text too, never the start of a block.
                marker = None
                content = inner
        quote = bool(_BLOCKQUOTE_PREFIX_RE.match(line))
        fence = _FENCE_OPEN_RE.match(content)
        if fence and fence.group("fence")[0] == "`" and "`" in fence.group("info"):
            fence = None  # an inline code span, not a fence
        single = bool(
            fence
            or _ATX_HEADING_RE.match(content)
            or _THEMATIC_BREAK_RE.match(content)
            or _SETEXT_UNDERLINE_RE.match(content)
        )
        html = bool(_HTML_BLOCK_START_RE.match(content)) and (
            not prev_para or bool(_HTML_INTERRUPT_RE.match(content))
        )
        if single or html or marker or (quote and not prev_quote):
            starts.add(i)
        if single:
            starts.add(i + 1)
        prev_quote = quote
        prev_para = not (single or html) and (item_text or not marker)
    return starts


def _list_item_interrupts(marker):
    """Say whether a list item may interrupt a paragraph (CommonMark 5.2).

    Only a non-empty bullet item or an ordered item that starts at 1 and is
    non-empty can; any other marker line in a paragraph is paragraph text.
    """
    if not marker.string[marker.end() :].strip():
        return False  # an empty item
    number = marker.group("marker")[:-1]
    return not number.isdigit() or int(number) == 1


def _mask_inline_code(text, source=None):
    """Mask inline code spans, which may cross lines within one paragraph.

    Spans are matched inside the segments found by _paragraph_starts. source is
    the text to find the segments in when text already has its block code
    masked (it must have the same lines); it defaults to text.
    """
    lines = text.split("\n")
    src = text if source is None else source
    starts = _paragraph_starts(src.split("\n"))
    out = []
    segment = []
    for i, line in enumerate(lines):
        if i in starts and segment:
            out.append(_mask_span_segment("\n".join(segment)))
            segment = []
        segment.append(line)
    out.append(_mask_span_segment("\n".join(segment)))
    return "\n".join(out)


def _mask_span_segment(text):
    """Mask the inline code spans of one segment.

    A span is a backtick run closed by a run of equal length within one
    paragraph. Outside a span a backslash escapes the next character, so an
    escaped backtick is literal text and cannot open a span; this is why the
    scan is not a single regex.
    """
    out = []
    pos = 0
    n = len(text)
    while pos < n:
        ch = text[pos]
        if ch == "\\":
            out.append(text[pos : pos + 2])
            pos += 2
            continue
        if ch != "`":
            out.append(ch)
            pos += 1
            continue
        run = _BACKTICK_RUN_RE.match(text, pos)
        ticks = run.group(0)
        limit = _BLANK_LINE_RE.search(text, run.end())
        limit = limit.start() if limit else n
        closer = re.compile(rf"(?<!`){ticks}(?!`)")
        end = None
        for m in closer.finditer(text, run.end() + 1, limit):
            end = m.end()
            break
        if end is None:
            out.append(ticks)
            pos = run.end()
        else:
            out.append(re.sub(r"[^\n]", _MASK_CHAR, text[pos:end]))
            pos = end
    return "".join(out)


def _mask_html_comments(line, shown, in_comment):
    """Mask the HTML comment text of one non-code line.

    shown is the same line with its inline code spans masked, including spans
    that began on an earlier line. Returns (masked line, still inside an
    unclosed comment). in_comment says the line starts inside a comment from an
    earlier line. A "<!--" inside a code span is not a comment start. A comment
    runs to its "-->" or, when unclosed, to the end of the text.
    """
    masked = list(line)

    def mask(start, stop):
        masked[start:stop] = _MASK_CHAR * (stop - start)

    pos = 0
    while True:
        if in_comment:
            end = line.find("-->", pos)
            if end < 0:
                mask(pos, len(line))
                break
            mask(pos, end + 3)
            pos = end + 3
            in_comment = False
        else:
            start = shown.find("<!--", pos)
            if start < 0:
                break
            mask(start, start + 4)
            pos = start + 4
            in_comment = True
    return "".join(masked), in_comment


def _mask_code(text, mask_raw_html=False):
    """Replace fenced, indented and inline code with a placeholder character.

    Newlines are kept. The placeholder is not whitespace, so a keyword followed
    by masked code is not mistaken for a keyword followed by a target. Raw HTML
    blocks are masked as well when mask_raw_html is set (see _mask_block_code).
    """
    return _mask_inline_code(_mask_block_code(text, mask_raw_html), _normalize_newlines(text))


def _strip_closing_keywords(text):
    """Remove closing keywords from live Markdown text, keeping their targets.

    Matching runs on a copy with code and HTML comments masked (see
    _mask_live_text) and each removal is applied to the same span of the
    original text, so code is preserved exactly. Substitution repeats until the
    text is stable: removing one keyword can expose another ("fixes fixes #1"
    becomes "fixes #1"). Matching runs over the whole text, so a keyword and
    target split across lines are caught.
    """
    text = _normalize_newlines(text)
    while True:
        live = _mask_live_text(text)
        matches = list(_LIVE_REF_ANYWHERE_RE.finditer(live))
        if not matches:
            return text
        for m in reversed(matches):
            text = text[: m.start("ref")] + text[m.start("target"):]


_CONTROL_CHARS_RE = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]|[\x00-\x1f\x7f]")


def _sanitize(text):
    """Neutralize text for a ::warning:: annotation (mirrors _gha_sanitize)."""
    text = _CONTROL_CHARS_RE.sub("", str(text))
    return text.replace("%", "%25").replace("::", "%3A%3A")


def _managed_tail_start(text, last=True):
    """Return (lines, start): the normalized lines of text and the index where
    the post-script verification block starts (len(lines) when there is none).

    The block starts at the "---" rule before the heading when only blank or
    issue-reference lines sit between them, otherwise at the heading itself.
    The heading and rule are located in a copy with code and HTML comments
    masked (see _mask_live_text), so an example of the heading is not the
    block; the returned lines are the original text.
    """
    lines = _normalize_newlines(text).split("\n")
    masked = _mask_live_text(text, mask_raw_html=True).split("\n")
    indexes = [i for i, line in enumerate(masked) if _VERIFICATION_HEADING_RE.match(line)]
    if not indexes:
        return lines, len(lines)
    idx = indexes[-1] if last else indexes[0]
    j = idx - 1
    while j >= 0 and (not masked[j].strip() or ISSUE_REF_RE.match(masked[j])):
        j -= 1
    start = j if j >= 0 and masked[j].strip() == "---" else j + 1
    return lines, start


def _managed_parts(current):
    """Return (refs, tail_text): the issue references and the verification
    block that a body update must preserve from the current body."""
    lines, start = _managed_tail_start(current, last=True)
    tail = lines[start:]
    # Mask the whole body, not the head alone, so a fence or comment that opens in
    # the head is closed (or not) exactly as the forge sees it; masking keeps
    # line indexes.
    masked_head = _mask_inline_markup(_mask_live_text(current, mask_raw_html=True)).split("\n")[:start]
    refs = []
    # Match over the whole head so references wrapped across lines keep every
    # target; whitespace inside a reference is collapsed to single spaces.
    # Code and HTML comments are masked first: a literal example or a commented
    # reference there is not a live reference and must not become one in the
    # replacement body, and a reference cannot match across masked text.
    for m in _EXISTING_REF_RE.finditer("\n".join(masked_head)):
        ref = re.sub(r"\s*\n\s*", " ", m.group("ref")).strip()
        if ref not in refs:
            refs.append(ref)
    return refs, "\n".join(tail).strip()


def _mask_live_text(text, mask_raw_html=False):
    """Mask everything a forge does not render as live text: fenced, indented
    and inline code, and HTML comments (an unclosed one runs to the end). Raw
    HTML blocks too when mask_raw_html is set; callers that edit the text leave
    them visible so a misparsed block cannot shield a closing keyword."""
    return _HTML_COMMENT_RE.sub(
        lambda m: re.sub(r"[^\n]", _MASK_CHAR, m.group(0)), _mask_code(text, mask_raw_html)
    )


# Inline markup whose text is not live prose: an HTML tag with its attributes,
# and the destination and title of an inline link or image or of a link
# reference definition. A closing reference there (<span title="Fixes #1">,
# [x](/y "Fixes #1")) is not rendered as one.
_HTML_ATTR = (
    r"[A-Za-z_:][\w:.-]*(?:\s*=\s*(?:[^\s\"'=<>`]+|'[^']*'|\"[^\"]*\"))?"
)
_HTML_TAG_RE = re.compile(
    rf"<[A-Za-z][A-Za-z0-9-]*(?:\s+{_HTML_ATTR})*\s*/?>|</[A-Za-z][A-Za-z0-9-]*\s*>"
)
_LINK_DEST = r"<(?:[^<>\n\\]|\\.)*>|(?:[^\s()<\\]|\\.|\((?:[^\s()\\]|\\.)*\))*"
_LINK_TITLE = r"\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|\((?:[^()\\]|\\.)*\)"
_INLINE_LINK_META_RE = re.compile(rf"(?<=\])\(\s*(?:{_LINK_DEST})(?:\s+(?:{_LINK_TITLE}))?\s*\)")
_LINK_DEFINITION_RE = re.compile(
    rf"^ {{0,3}}\[[^\]\n]+\]:[ \t]*(?:{_LINK_DEST})(?:\s+(?:{_LINK_TITLE}))?[ \t]*$",
    re.MULTILINE,
)


def _mask_inline_markup(live):
    """Mask HTML tags and link destinations/titles in text that went through
    _mask_live_text, so a reference inside them is not read as live text."""
    for pattern in (_HTML_TAG_RE, _INLINE_LINK_META_RE, _LINK_DEFINITION_RE):
        live = pattern.sub(lambda m: re.sub(r"[^\n]", _MASK_CHAR, m.group(0)), live)
    return live


# Raw HTML blocks that run to an explicit end condition rather than to a blank
# line (CommonMark HTML block types 1, 3, 4 and 5). One that is never closed
# absorbs everything after it as literal HTML.
_RAW_HTML_OPEN_RE = re.compile(
    r"<(?:(?P<raw>(?:pre|script|style|textarea)(?=[\s>]|$))|(?P<pi>\?)|(?P<cdata>!\[CDATA\[)|(?P<decl>![A-Za-z]))",
    re.IGNORECASE | re.MULTILINE,
)
def _has_unclosed_raw_html(live):
    """Return True when live text opens a raw HTML block it never closes.

    Conservative: an opener anywhere in a line counts, so prose that merely
    mentions such a tag outside code also fails the check.
    """
    for m in _RAW_HTML_OPEN_RE.finditer(live):
        kind = next(name for name in _RAW_HTML_CLOSE_RE if m.group(name) is not None)
        if not _RAW_HTML_CLOSE_RE[kind].search(live, m.end()):
            return True
    return False


def managed_sections_exposed(merged, current):
    """Return True when merged still shows the preserved parts of current.

    The closing references and the "### Post-script verification" heading that
    build_pr_body preserves from current must each be found outside code and
    HTML comments in merged, as a forge would render it. A proposal that opens a
    fence, comment or raw HTML block (<pre>, <script>, ...) it never closes
    would absorb the appended sections, so this returns False when exposure
    cannot be proven.
    """
    refs, tail_text = _managed_parts(current)
    if (refs or tail_text) and _has_unclosed_raw_html(_mask_live_text(merged)):
        return False
    # Raw HTML blocks, tags and link titles are literal, so a heading or
    # reference found only there is not exposed.
    live = _mask_inline_markup(_mask_live_text(merged, mask_raw_html=True))
    if tail_text and not any(_VERIFICATION_HEADING_RE.match(line) for line in live.split("\n")):
        return False
    found ={re.sub(r"\s*\n\s*", " ", m.group("ref")).strip() for m in _EXISTING_REF_RE.finditer(live)}
    return all(ref in found for ref in refs)


def build_pr_body(proposed, current):
    """Merge the agent's proposed body with the post-script-owned parts of current.

    Keeps the current issue references and verification block, and drops any
    copies of them from the proposed text; closing keywords the proposal adds
    anywhere in its text are removed. Returns "" when nothing of the
    proposal remains. The result is not checked for Markdown that hides the
    appended sections; callers use managed_sections_exposed for that.
    """
    refs, tail_text = _managed_parts(current)
    lines, start = _managed_tail_start(proposed, last=False)
    live_head = _mask_live_text(proposed).split("\n")[:start]
    # Whole live reference lines are dropped; inline references lose their
    # keyword so the proposal cannot add an issue-closing instruction. Code and
    # HTML comments are never edited: a line holding any is kept, and only its
    # live keyword is removed.
    kept = [
        line
        for line, live in zip(lines, live_head)
        if _MASK_CHAR in live or not _LIVE_ISSUE_REF_RE.match(live)
    ]
    # Trim before sanitizing, and repeat until the text is stable: trimming
    # can turn an indented line (code at the start of the text) into live text,
    # so the keyword removal must run on the final, trimmed form.
    description = "\n".join(kept)
    while True:
        description = _strip_closing_keywords(description.strip())
        if description == description.strip():
            break
    if not description:
        return ""
    parts = [description]
    if refs:
        parts.append("\n".join(refs))
    if tail_text:
        parts.append(tail_text)
    return "\n\n".join(parts)


# A GitLab quick action: a line that starts with "/" and a command name, such as
# "/close" or "/label ~x". GitLab may run these from an issuable description.
# The prefix is any non-newline whitespace, Unicode blanks included, so a
# leading NBSP or em space cannot hide a command from the filter.
_QUICK_ACTION_RE = re.compile(r"^[^\S\n]*/\w", re.MULTILINE)


def has_quick_action(text):
    """Say whether any line of text looks like a GitLab quick action.

    Deliberately not Markdown-aware: a line in code or a comment is flagged too,
    so a parsing mistake cannot let a command through.
    """
    return bool(_QUICK_ACTION_RE.search(_normalize_newlines(text)))


def _sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _get_pr_metadata(repo, pr_number, forge):
    """Return the live (title, body) of the PR/MR."""
    if forge == "gitlab":
        result = _gitlab_mr_request(repo, pr_number, "GET")
        data = json.loads(result.stdout)
        return data.get("title") or "", data.get("description") or ""
    result = subprocess.run(
        ["gh", "pr", "view", str(pr_number), "--repo", repo, "--json", "title,body"],
        check=True,
        capture_output=True,
        text=True,
    )
    data = json.loads(result.stdout)
    return data.get("title") or "", data.get("body") or ""


def _edit_pr_metadata(repo, pr_number, forge, title=None, body=None):
    """Update only the given fields of the PR/MR."""
    if forge == "gitlab":
        fields = []
        if title is not None:
            fields.append(("title", title))
        if body is not None:
            fields.append(("description", body))
        _gitlab_mr_request(repo, pr_number, "PUT", "", fields)
        return
    cmd = ["gh", "pr", "edit", str(pr_number), "--repo", repo]
    if title is not None:
        cmd.append(f"--title={title}")
    if body is not None:
        cmd += ["--body-file", "-"]
    subprocess.run(cmd, input=body, check=True, capture_output=True, text=True)


def apply_pr_metadata(data, repo, pr_number, schema_validated, secret_scan_passed, dry_run=False):
    """Apply proposed pr_title / pr_body. Return outcome notes for the summary.

    Returns [] when no metadata was proposed. Never raises for forge errors.
    """
    proposed_title = data.get("pr_title") or ""
    proposed_body = data.get("pr_body") or ""
    if not proposed_title and not proposed_body:
        return []

    def skipped(reason, detail=""):
        # Forge error detail goes to the job log only, not the public comment.
        suffix = f": {_sanitize(detail)}" if detail else ""
        print(f"::warning::PR metadata not updated: {reason}{suffix}", file=sys.stderr)
        return [f"proposed update not applied ({reason})"]

    if not schema_validated:
        return skipped("structured output was not schema-validated")
    if not secret_scan_passed:
        return skipped("structured output secret scan did not run or did not pass")

    forge = os.environ.get("FULLSEND_FORGE", "github")
    try:
        live_title, live_body = _get_pr_metadata(repo, pr_number, forge)
    except subprocess.CalledProcessError as e:
        return skipped("could not read current metadata", e.stderr or e)
    except (ValueError, OSError) as e:
        return skipped("could not read current metadata", e)

    notes = []
    new_title = None
    new_body = None
    if proposed_title:
        if _sha256(live_title) != data.get("pr_title_base_sha256"):
            print(
                "::warning::PR title changed since the fix agent read it — not overwriting",
                file=sys.stderr,
            )
            notes.append("title not updated (changed since the agent read it)")
        elif proposed_title == live_title:
            notes.append("title already up to date")
        else:
            new_title = proposed_title
    if proposed_body:
        merged = build_pr_body(proposed_body, live_body)
        if _sha256(live_body) != data.get("pr_body_base_sha256"):
            print(
                "::warning::PR body changed since the fix agent read it — not overwriting",
                file=sys.stderr,
            )
            notes.append("body not updated (changed since the agent read it)")
        elif forge == "gitlab" and has_quick_action(merged):
            # Check the description actually submitted, not just the proposal:
            # the preserved live verification tail is re-sent unchanged.
            print(
                "::warning::PR body not updated: the resulting description has a line that"
                " starts with a GitLab quick action",
                file=sys.stderr,
            )
            notes.append("body not updated (description contains a GitLab quick-action line)")
        elif not merged:
            print(
                "::warning::Proposed PR body is empty after removing post-script-managed sections",
                file=sys.stderr,
            )
            notes.append("body not updated (proposal empty after removing managed sections)")
        elif merged == live_body:
            notes.append("body already up to date")
        elif not managed_sections_exposed(merged, live_body):
            print(
                "::warning::PR body not updated: the proposed Markdown (for example an"
                " unclosed code fence or HTML comment) could hide the preserved closing"
                " references or the post-script verification block",
                file=sys.stderr,
            )
            notes.append(
                "body not updated (proposed Markdown could hide the preserved"
                " references or verification block)"
            )
        else:
            new_body = merged

    if new_title is None and new_body is None:
        return notes

    changed = [name for name, value in (("title", new_title), ("body", new_body)) if value is not None]
    if dry_run:
        print(f"  [dry-run] Would update PR {' and '.join(changed)}")
        return notes + [f"{name} updated" for name in changed]
    try:
        _edit_pr_metadata(repo, pr_number, forge, title=new_title, body=new_body)
    except subprocess.CalledProcessError as e:
        print(
            f"::warning::Failed to update PR {' and '.join(changed)}: {_sanitize(e.stderr or e)}",
            file=sys.stderr,
        )
        return notes + [f"{name} update failed" for name in changed]
    except (ValueError, OSError) as e:
        print(
            f"::warning::Failed to update PR {' and '.join(changed)}: {_sanitize(e)}",
            file=sys.stderr,
        )
        return notes + [f"{name} update failed" for name in changed]
    print(f"Updated PR {' and '.join(changed)}")
    return notes + [f"{name} updated" for name in changed]


def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]

    if len(argv) < 3:
        print(
            "Usage: process-fix-result.py <fix-result.json> <owner/repo> <pr-number> [--dry-run]",
            file=sys.stderr,
        )
        return 1

    result_file = argv[0]
    repo = argv[1]
    pr_number = argv[2]
    dry_run = "--dry-run" in argv

    try:
        with open(result_file) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"::error::Cannot read {result_file}: {e}", file=sys.stderr)
        return 1

    schema_validated = False
    if jsonschema is not None:
        schema_path = os.environ.get("FULLSEND_OUTPUT_SCHEMA")
        if not schema_path:
            print(
                "::error::Cannot resolve schema path: FULLSEND_OUTPUT_SCHEMA environment variable is not set",
                file=sys.stderr,
            )
            return 1
        try:
            with open(schema_path) as f:
                schema = json.load(f)
        except (json.JSONDecodeError, OSError) as e:
            print(f"::error::Cannot read schema {schema_path}: {e}", file=sys.stderr)
            return 1

        try:
            jsonschema.validate(instance=data, schema=schema)
        except jsonschema.ValidationError as e:
            msg = e.message.replace("\r", "").replace("\n", " ").replace("::", ": :")
            print(f"::error::fix-result.json failed schema validation: {msg}", file=sys.stderr)
            return 1
        schema_validated = True
    else:
        print("::warning::jsonschema not installed — skipping schema validation")

    actions = data.get("actions", [])
    valid_types = {"fix", "disagree"}
    for a in actions:
        atype = a.get("type", "")
        if atype not in valid_types:
            safe_atype = atype.replace("\r", "").replace("\n", " ").replace("::", ": :")
            print(f"::warning::Unknown action type '{safe_atype}' — ignored", file=sys.stderr)
    fixed = sum(1 for a in actions if a.get("type") == "fix")
    disagreed = sum(1 for a in actions if a.get("type") == "disagree")
    print(f"Processed: {fixed} fixed, {disagreed} disagreed")

    summary_body = build_summary_body(data)
    try:
        metadata_notes = apply_pr_metadata(
            data,
            repo,
            pr_number,
            schema_validated=schema_validated,
            secret_scan_passed=os.environ.get("FIX_RESULT_SECRET_SCAN") == "passed",
            dry_run=dry_run,
        )
    except Exception as e:  # never let a metadata problem block the summary
        print(f"::warning::PR metadata update failed: {_sanitize(e)}", file=sys.stderr)
        metadata_notes = ["proposed update failed"]
    if metadata_notes:
        summary_body += "\n\n**PR metadata:** " + "; ".join(metadata_notes)
    # Record the post-script's trailer strip so the rewrite is visible.
    signoff_note = ""
    try:
        stripped = int(os.environ.get("SIGNOFF_STRIPPED_COUNT", "0") or "0")
    except ValueError:
        stripped = 0
    if stripped > 0:
        plural = "s" if stripped != 1 else ""
        signoff_note = (
            f"\n\n_Removed a Signed-off-by trailer from {stripped} agent commit{plural}._"
        )
    suffix = signoff_note + FOOTER + ATTRIBUTION
    success = post_summary(repo, pr_number, summary_body, suffix=suffix, dry_run=dry_run)

    return 0 if success else 2


if __name__ == "__main__":
    sys.exit(main())
