"""Unit tests for tools/changelog_section.py (release notes extraction)."""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("changelog_section", os.path.join(HERE, "..", "tools", "changelog_section.py"))
cs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cs)

SAMPLE = """# Changelog

## [Unreleased]

## [1.2.0] - 2026-01-01
Intro line.
- see [report](field-reports/x.md) and [abs](https://example.com/a) and [anchor](#top)

## [1.1.0] - 2025-12-01
- old
"""


class ChangelogSectionTest(unittest.TestCase):
    def test_extracts_only_requested_section(self):
        body = cs.section(SAMPLE, "1.2.0")
        self.assertTrue(body.startswith("Intro line."))
        self.assertNotIn("old", body)

    def test_relative_links_become_absolute(self):
        body = cs.section(SAMPLE, "1.2.0")
        self.assertIn("](https://github.com/seaworld008/centos7-lighthouse/blob/main/field-reports/x.md)", body)
        self.assertIn("](https://example.com/a)", body)
        self.assertIn("](#top)", body)

    def test_missing_version(self):
        self.assertIsNone(cs.section(SAMPLE, "9.9.9"))

    def test_real_changelog_has_current_version(self):
        import json
        root = os.path.join(HERE, "..")
        with open(os.path.join(root, ".claude-plugin", "plugin.json"), encoding="utf-8") as f:
            v = json.load(f)["version"]
        with open(os.path.join(root, "CHANGELOG.md"), encoding="utf-8") as f:
            self.assertTrue(cs.section(f.read(), v))


if __name__ == "__main__":
    unittest.main()
