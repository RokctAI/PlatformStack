#!/usr/bin/env python3
# Copyright (c) 2026 ROKCT INTELLIGENCE (PTY) LTD
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, version 3.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
"""Write one env file per Next.js site from Occultation production.env.

Occultation keeps ONE website block, from "# WebApp Native Public Endpoints" to
"##########END_NEXTJS##########" (Ray, 2026-11-27). Values that differ per site are
placeholders:

  ${APP_<KEY>}  -> <APP>_<KEY> from the env file, where <APP> is the site's "app" in
                   sites.json (STICKS, SUPACHARGE, ...). ${APP_NAME} also tries
                   <APP>_APP_NAME. A site without "app" gets an empty value.
  ${APP_SITE_URL} -> https://<first domain of the site>
  ${OTHER}      -> OTHER from the env file (shared value).

A line whose value ends up empty is left out, so the site's own default applies.
Values are never printed.

  python3 platform/scripts/site_env.py <production.env> <out dir>
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sites as sites_mod  # noqa: E402

START = "# WebApp Native Public Endpoints"
END = "##########END_NEXTJS##########"
REF = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")
LINE = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")


def parse(text):
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    values, block, inside = {}, [], False
    for l in lines:
        if l.strip() == START:
            inside = True
            continue
        if l.strip() == END:
            inside = False
            continue
        m = LINE.match(l)
        if not m:
            continue
        if inside:
            block.append((m.group(1), m.group(2)))
        else:
            values.setdefault(m.group(1), m.group(2))
    return values, block


def render(site, values, block):
    app = site.get("app")
    local = {"APP_SITE_URL": "https://" + site["domains"][0]}

    def look(name):
        if name in local:
            return local[name]
        if name.startswith("APP_"):
            if not app:
                return ""
            key = name[4:]
            got = values.get(f"{app}_{key}", "")
            if not got and key == "NAME":
                got = values.get(f"{app}_APP_NAME", "")
            return got
        return values.get(name, "")

    out = []
    for key, raw in block:
        val = REF.sub(lambda m: look(m.group(1)), raw).strip()
        if val:
            out.append(f"{key}={val}")
    return "\n".join(out) + ("\n" if out else "")


def main(argv):
    if len(argv) != 3:
        raise SystemExit(__doc__)
    values, block = parse(Path(argv[1]).read_text())
    out = Path(argv[2])
    out.mkdir(parents=True, exist_ok=True)
    for s in sites_mod.load():
        p = out / f"{s['name']}.env"
        p.write_text(render(s, values, block))
        p.chmod(0o600)
        print(f"{s['name']}: {p.read_text().count(chr(10))} key(s)")


if __name__ == "__main__":
    main(sys.argv)
