#!/usr/bin/env python3
"""Local tracker viewer server.

Stdlib-only HTTP server that serves the SPA shell, the tracker tree as JSON,
and raw markdown files under .features/. The walking-skeleton subset: no
parsing, no rendering — clients render or display the bytes themselves.
"""

from __future__ import annotations

import argparse
import errno
import json
import re
import subprocess
import sys
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

def resolve_consumer_root(start: Path) -> Path | None:
    """Walk ``start`` upward looking for a ``.formann`` ancestor.

    Returns the directory containing ``.formann`` (the consumer root), or
    ``None`` if no such ancestor exists. Mirrors ``build-image.sh``'s
    ``HOST_REPO`` walk and ``tracker-snapshot``'s ``tracker_root`` walk —
    consumer-side resources must be discovered from ``$cwd``, never from
    ``__file__``: when the viewer is invoked through ``iot/.formann/``,
    ``Path(__file__).resolve()`` physically follows the symlink and lands
    in the framework checkout, away from the consumer's ``.features/``.
    """
    walk = start if start.is_absolute() else start.absolute()
    while True:
        if (walk / ".formann").exists():
            return walk
        if walk.parent == walk:
            return None
        walk = walk.parent


# STATIC_DIR is framework-side: it sits alongside ``serve.py`` regardless of
# where the consumer keeps its ``.features/``. TRACKER_DIR is consumer-side:
# the walk above finds it; without a ``.formann`` ancestor we fall back to
# ``cwd`` so direct ``python3 serve.py`` invocations from a project root
# still work for projects that haven't adopted Formann.
_CONSUMER_ROOT = resolve_consumer_root(Path.cwd()) or Path.cwd()
TRACKER_DIR = _CONSUMER_ROOT / ".features"
STATIC_DIR = Path(__file__).resolve().parent / "static"

DEFAULT_PORT = 8765

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
}


ISSUE_FILENAME_RE = re.compile(r"^(\d+)-[A-Za-z0-9-]+\.md$")
FRONTMATTER_KEYS = ("status", "category", "type")
FRONTMATTER_LINE_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*)\s*:\s*(.*?)\s*$")


def parse_frontmatter(text: str) -> tuple[dict, str]:
    """Parse a YAML frontmatter block from the start of ``text``.

    Returns ``(metadata, remainder)``. When ``text`` does not begin with a
    line that is exactly ``---``, returns ``({}, text)`` — files without
    frontmatter are valid and yield empty metadata.

    Inside a frontmatter block every line must match ``key: value``;
    blank lines, comments, and indented continuations are not permitted.
    An opener with no matching closer, or any non-conforming line inside
    the block, raises :class:`ValueError`. Values are returned as raw
    strings — no type coercion, no quote stripping, no list/map/date/bool
    support.
    """
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return {}, text
    out: dict = {}
    for i in range(1, len(lines)):
        line = lines[i]
        if line == "---":
            return out, "\n".join(lines[i + 1:])
        m = FRONTMATTER_LINE_RE.match(line)
        if not m:
            raise ValueError(f"Malformed frontmatter line: {line!r}")
        out[m.group(1)] = m.group(2)
    raise ValueError("Frontmatter block was not closed")


def extract_title(text: str) -> str | None:
    """Return the first level-1 heading, or ``None`` if a level-2 heading
    appears first or no heading is present."""
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("## "):
            return None
        if stripped.startswith("# "):
            return stripped[2:].strip()
    return None


def parse_issue_metadata(text: str) -> dict:
    """Parse the leading metadata from an issue file.

    Returns a dict with any of ``title``, ``status``, ``category``,
    ``type``. The three triage fields come from the YAML frontmatter at
    the top of the file (lowercase keys); unknown frontmatter keys are
    silently ignored. ``title`` is the first level-1 heading after the
    frontmatter.

    A malformed frontmatter block raises :class:`ValueError` so the
    viewer surfaces broken metadata instead of silently rendering with
    fields missing.
    """
    fm, body = parse_frontmatter(text)
    out: dict = {}
    for key in FRONTMATTER_KEYS:
        if key in fm:
            out[key] = fm[key]
    title = extract_title(body)
    if title is not None:
        out["title"] = title
    return out


def collect_mtime(root: Path) -> float:
    """Return the maximum mtime of ``root`` and any file beneath it.

    Captures real recency (e.g. an edit to a single issue file) rather than
    just the directory's own stat, which on many filesystems only changes
    when entries are added or removed.
    """
    try:
        latest = root.stat().st_mtime
    except OSError:
        return 0.0
    for sub in root.rglob("*"):
        try:
            latest = max(latest, sub.stat().st_mtime)
        except OSError:
            pass
    return latest


def _build_feature(entry: Path, section: str) -> dict | None:
    """Build a feature dict, or ``None`` if the directory has neither a PRD
    nor any well-formed issue file (i.e. the whole feature is empty)."""
    prd = (entry / "PRD.md").is_file()
    issues: list[dict] = []
    issues_dir = entry / "issues"
    if issues_dir.is_dir():
        for issue in sorted(issues_dir.iterdir(), key=lambda p: p.name):
            if not issue.is_file():
                continue
            m = ISSUE_FILENAME_RE.match(issue.name)
            if not m:
                continue
            meta: dict = {
                "path": f"issues/{issue.name}",
                "number": m.group(1),
            }
            try:
                meta.update(parse_issue_metadata(issue.read_text(encoding="utf-8")))
            except OSError:
                pass
            except ValueError as e:
                # Malformed frontmatter: keep the issue listed but flag it
                # so the viewer can surface the parse error instead of
                # silently rendering without pills.
                meta["error"] = str(e)
            issues.append(meta)
    if not prd and not issues:
        return None
    return {
        "slug": entry.name,
        "section": section,
        "mtime": int(collect_mtime(entry)),
        "prd": prd,
        "issues": issues,
    }


def build_tree() -> list[dict]:
    """Return the tree of active and archived features.

    Walks both ``.features/<feature>/`` (active) and ``.features/.archived/<feature>/``
    (archive). Each feature carries its ``section`` and ``mtime`` so the
    client can sort and tab-route. Empty feature directories (no PRD, no
    well-formed issues) and stray non-issue files are silently dropped.
    """
    features: list[dict] = []
    if not TRACKER_DIR.is_dir():
        return features
    for entry in sorted(TRACKER_DIR.iterdir(), key=lambda p: p.name):
        if not entry.is_dir() or entry.name == ".archived":
            continue
        feat = _build_feature(entry, "active")
        if feat is not None:
            features.append(feat)
    archived_dir = TRACKER_DIR / ".archived"
    if archived_dir.is_dir():
        for entry in sorted(archived_dir.iterdir(), key=lambda p: p.name):
            if not entry.is_dir():
                continue
            feat = _build_feature(entry, "archive")
            if feat is not None:
                features.append(feat)
    return features


class Handler(BaseHTTPRequestHandler):
    server_version = "TrackerViewer/0.1"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[tracker] " + fmt % args + "\n")

    def _send(self, status: int, content_type: str, body) -> None:
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_404(self, msg: str = "Not found") -> None:
        self._send(404, "text/plain; charset=utf-8", msg)

    def do_GET(self) -> None:  # noqa: N802 — BaseHTTPRequestHandler protocol
        path = unquote(self.path.split("?", 1)[0])

        if path in ("/", "/index.html"):
            self._serve_static("index.html")
            return

        if path == "/api/tree":
            body = json.dumps(build_tree(), indent=2)
            self._send(200, "application/json; charset=utf-8", body)
            return

        if path.startswith("/tracker/static/"):
            self._serve_static(path[len("/tracker/static/"):])
            return

        if path.startswith("/raw/"):
            self._serve_raw(path[len("/raw/"):])
            return

        self._send_404()

    def _serve_static(self, rel: str) -> None:
        if not rel:
            self._send_404()
            return
        target = (STATIC_DIR / rel).resolve()
        try:
            target.relative_to(STATIC_DIR.resolve())
        except ValueError:
            self._send_404()
            return
        if not target.is_file():
            self._send_404()
            return
        ctype = CONTENT_TYPES.get(target.suffix, "application/octet-stream")
        self._send(200, ctype, target.read_bytes())

    def _serve_raw(self, rel: str) -> None:
        if not rel:
            self._send_404()
            return
        target = (TRACKER_DIR / rel).resolve()
        try:
            target.relative_to(TRACKER_DIR.resolve())
        except ValueError:
            self._send_404()
            return
        if not target.is_file() or target.suffix != ".md":
            self._send_404()
            return
        self._send(200, "text/plain; charset=utf-8", target.read_bytes())


def find_listener_pid(port: int) -> int | None:
    """Return the PID of the process listening on ``port``, or ``None`` if it
    can't be determined (lsof missing, no match, unparseable output)."""
    try:
        result = subprocess.run(
            ["lsof", "-ti", f"tcp:{port}", "-sTCP:LISTEN"],
            capture_output=True, text=True, timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    pid_str = result.stdout.strip().split("\n", 1)[0]
    try:
        return int(pid_str)
    except ValueError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Local tracker viewer.")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help=f"port to listen on (default {DEFAULT_PORT})")
    parser.add_argument("--no-browser", action="store_true",
                        help="do not open a browser on startup")
    args = parser.parse_args()

    try:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as e:
        if e.errno != errno.EADDRINUSE:
            raise
        pid = find_listener_pid(args.port)
        print(f"Port {args.port} is already in use.", file=sys.stderr)
        if pid is not None:
            print(f"Stop the existing server with: kill {pid}", file=sys.stderr)
        return 1
    url = f"http://localhost:{args.port}"
    print(f"Tracker viewer running at {url}", flush=True)
    print("Press Ctrl-C to stop.", flush=True)
    if not args.no_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.", flush=True)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
