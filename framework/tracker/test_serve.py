"""Tests for the tracker viewer's frontmatter parser.

Stdlib-only (``unittest``); no test runner dependency. Run with::

    python -m unittest tracker.test_serve
"""

from __future__ import annotations

import unittest

from tracker.serve import (
    extract_title,
    parse_frontmatter,
    parse_issue_metadata,
)


class TestParseFrontmatter(unittest.TestCase):
    def test_no_leading_marker_returns_empty_dict(self) -> None:
        text = "# Title\n\nbody\n"
        meta, body = parse_frontmatter(text)
        self.assertEqual(meta, {})
        self.assertEqual(body, text)

    def test_empty_input_returns_empty_dict(self) -> None:
        meta, body = parse_frontmatter("")
        self.assertEqual(meta, {})
        self.assertEqual(body, "")

    def test_well_formed_block_parses_keys_and_values(self) -> None:
        text = "---\nstatus: done\ncategory: bug\ntype: AFK\n---\n\n# Title\n\nbody\n"
        meta, body = parse_frontmatter(text)
        self.assertEqual(meta, {"status": "done", "category": "bug", "type": "AFK"})
        self.assertEqual(body, "\n# Title\n\nbody\n")

    def test_unknown_keys_are_kept_as_strings(self) -> None:
        # The parser is additive — it doesn't filter keys; the issue-metadata
        # layer is the one that picks the three it cares about.
        text = "---\nstatus: done\nassignee: arne\n---\n"
        meta, _ = parse_frontmatter(text)
        self.assertEqual(meta, {"status": "done", "assignee": "arne"})

    def test_values_are_plain_strings_no_coercion(self) -> None:
        # No list/map/date/bool support — the value is whatever sits to the
        # right of the colon, untouched.
        text = "---\nflag: true\ncount: 7\nwhen: 2026-05-03\nlist: [a, b]\n---\n"
        meta, _ = parse_frontmatter(text)
        self.assertEqual(meta["flag"], "true")
        self.assertEqual(meta["count"], "7")
        self.assertEqual(meta["when"], "2026-05-03")
        self.assertEqual(meta["list"], "[a, b]")

    def test_unclosed_block_raises(self) -> None:
        text = "---\nstatus: done\ncategory: bug\n"
        with self.assertRaises(ValueError):
            parse_frontmatter(text)

    def test_malformed_line_in_block_raises(self) -> None:
        text = "---\nstatus: done\nthis is not key:value shaped... wait it is\n: nope\n---\n"
        with self.assertRaises(ValueError):
            parse_frontmatter(text)

    def test_blank_line_in_block_raises(self) -> None:
        text = "---\nstatus: done\n\ncategory: bug\n---\n"
        with self.assertRaises(ValueError):
            parse_frontmatter(text)

    def test_remainder_preserves_trailing_content(self) -> None:
        text = "---\nstatus: done\n---\nbody line one\n\nbody line two\n"
        _, body = parse_frontmatter(text)
        self.assertEqual(body, "body line one\n\nbody line two\n")


class TestExtractTitle(unittest.TestCase):
    def test_first_h1_is_returned(self) -> None:
        self.assertEqual(extract_title("# Hello\n\nbody\n"), "Hello")

    def test_h2_before_h1_blocks_extraction(self) -> None:
        self.assertIsNone(extract_title("## Section\n# Hello\n"))

    def test_no_heading_returns_none(self) -> None:
        self.assertIsNone(extract_title("plain text\n"))


class TestParseIssueMetadata(unittest.TestCase):
    def test_full_frontmatter_and_title(self) -> None:
        text = (
            "---\n"
            "status: ready-for-agent\n"
            "category: enhancement\n"
            "type: AFK\n"
            "---\n"
            "\n"
            "# Implement the thing\n"
            "\n"
            "## What to build\n"
        )
        meta = parse_issue_metadata(text)
        self.assertEqual(
            meta,
            {
                "status": "ready-for-agent",
                "category": "enhancement",
                "type": "AFK",
                "title": "Implement the thing",
            },
        )

    def test_missing_keys_are_simply_absent(self) -> None:
        text = "---\nstatus: done\n---\n\n# Just status\n"
        meta = parse_issue_metadata(text)
        self.assertEqual(meta, {"status": "done", "title": "Just status"})

    def test_unknown_keys_silently_ignored(self) -> None:
        text = "---\nstatus: done\nassignee: arne\n---\n\n# Title\n"
        meta = parse_issue_metadata(text)
        self.assertEqual(meta, {"status": "done", "title": "Title"})

    def test_no_frontmatter_returns_title_only(self) -> None:
        # PRD-style files have no frontmatter; they should still yield a title.
        text = "# A PRD\n\nbody\n"
        self.assertEqual(parse_issue_metadata(text), {"title": "A PRD"})


if __name__ == "__main__":
    unittest.main()
