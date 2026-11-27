# Copyright (c) 2026 ROKCT INTELLIGENCE (PTY) LTD
# SPDX-License-Identifier: AGPL-3.0-only
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("sites", Path(__file__).resolve().parent.parent / "sites.py")
sites = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sites)

GOOD = {"name": "polaris", "repo": "https://github.com/RokctAI/polaris-web", "ref": "abc123",
        "domains": ["polaris.example.co.za", "www.polaris.example.co.za"], "memory": "512m"}


def load(entries):
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "s.json"
        p.write_text(json.dumps({"sites": entries}))
        return sites.load(p)


class SitesTest(unittest.TestCase):
    def test_render(self):
        s = load([GOOD])
        c = sites.render_compose(s)
        self.assertIn("site-polaris:", c)
        self.assertIn('SHELL_REF: "abc123"', c)
        self.assertIn('image: "rokct/site-polaris:abc123"', c)
        self.assertIn("memory: 512m", c)
        r = sites.render_routes(s)
        self.assertIn("polaris.example.co.za http://site-polaris:3000", r)
        self.assertIn("www.polaris.example.co.za http://site-polaris:3000", r)

    def test_empty(self):
        self.assertIn("services: {}", sites.render_compose([]))

    def test_rejects(self):
        for bad in ({"name": "Bad Name"}, {"repo": "http://evil"}, {"domains": []},
                    {"domains": ["x;rm -rf"]}, {"ref": "a b"}, {"memory": "lots"}):
            with self.assertRaises(SystemExit):
                load([{**GOOD, **bad}])
        with self.assertRaises(SystemExit):
            load([GOOD, {**GOOD, "name": "other"}])  # same domain twice

    def test_committed_files_current(self):
        self.assertEqual(sites.main(["--check"]), 0)


if __name__ == "__main__":
    unittest.main()
