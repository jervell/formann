#!/usr/bin/env python3
"""Render a sub-agent's transcript JSONL as a plain-text conversation.

Usage:
    render-transcript.py <agentId>

Reads ~/.claude/projects/<cwd-slug>/<sessionId>/subagents/agent-<agentId>.jsonl
where sessionId comes from $CLAUDE_CODE_SESSION_ID and cwd-slug is the current
working directory with `/` replaced by `-`.

Emits the conversation as a USER:/ASSISTANT: prefixed plain-text log,
preserving content-block order. Tool calls, tool results, and (when
present) thinking blocks are inlined under the role that produced them.
Anthropic currently redacts thinking blocks from new sub-agent
transcripts, but historical transcripts may contain them — render
defensively.
"""

import json
import os
import re
import sys
from pathlib import Path


def transcript_path(agent_id: str) -> Path:
    session_id = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if not session_id:
        sys.exit("CLAUDE_CODE_SESSION_ID not set")
    slug = re.sub(r"[/.]", "-", os.getcwd())
    return (
        Path.home()
        / ".claude"
        / "projects"
        / slug
        / session_id
        / "subagents"
        / f"agent-{agent_id}.jsonl"
    )


def render_inner(block: dict) -> str:
    """Render a content block found inside a tool_result.content list."""
    t = block.get("type")
    if t == "text":
        return block.get("text", "")
    if t == "tool_reference":
        return f"[tool reference: {block.get('tool_name', '?')}]"
    if t == "image":
        return "[image]"
    return f"[{t}]"


def render_block(block: dict) -> str:
    t = block.get("type")
    if t == "text":
        return block.get("text", "")
    if t == "thinking":
        return f"[reasoning]\n{block.get('thinking', '')}"
    if t == "image":
        return "[image]"
    if t == "tool_use":
        name = block.get("name", "?")
        args = json.dumps(block.get("input", {}), indent=2, ensure_ascii=False)
        return f"[tool call: {name}]\n{args}"
    if t == "tool_result":
        content = block.get("content", "")
        if isinstance(content, list):
            content = "\n".join(render_inner(b) for b in content if isinstance(b, dict))
        return f"[tool result]\n{content}"
    return f"[unhandled block type: {t}]"


def render_message(line: dict) -> str | None:
    if line.get("type") not in ("user", "assistant"):
        return None
    msg = line.get("message")
    if not isinstance(msg, dict):
        return None
    role = msg.get("role")
    if role not in ("user", "assistant"):
        return None
    content = msg.get("content", [])
    if isinstance(content, str):
        body = content
    elif isinstance(content, list):
        body = "\n\n".join(render_block(b) for b in content if isinstance(b, dict))
    else:
        return None
    return f"{role.upper()}:\n{body}"


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <agentId>")
    path = transcript_path(sys.argv[1])
    if not path.exists():
        sys.exit(f"no transcript at {path}")
    parts: list[str] = []
    with path.open() as fh:
        for raw in fh:
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                continue
            rendered = render_message(obj)
            if rendered is not None:
                parts.append(rendered)
    sys.stdout.write("\n\n".join(parts))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
