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

"""Build-time patches to a stock Frappe v16 checkout (no fork), so a
composed rcore installs and migrates on Postgres. Used by
build_ignition_root.sh; documented in platform/ignition/README.md.

    patch_frappe_v16.py <path to apps/frappe>

Each patch replaces one exact block of text. A patch already applied is
left alone (so a re-run is a no-op); a block that is not found exactly once
fails the build, so a Frappe change that moves the code is seen, not
silently skipped. Prints the names of the patches, one per line, on stdout.
"""

import os
import sys

# 1. fixtures-duplicate-key: the same change build_ecosystem.sh applies to the
#    bench build ("Patching fixtures.py for PostgreSQL unique constraints").
#    On Postgres the second fixture sync (migrate) raises a duplicate key on
#    records an earlier sync inserted; skip that fixture file and roll back.
FIXTURES_OLD = """\t\ttry:
\t\t\timport_doc(file_path, sort=True)
\t\texcept (ImportError, frappe.DoesNotExistError) as e:
\t\t\t# fixture syncing for missing doctypes
\t\t\tprint(f"Skipping fixture syncing from the file {fname}. Reason: {e}")
"""
FIXTURES_NEW = FIXTURES_OLD + """\t\texcept Exception as e:
\t\t\tif any(x in str(e).lower() for x in ["duplicate key", "unique constraint", "already exists", "violates unique"]):
\t\t\t\tprint(f"Skipping duplicate fixture {fname}: {e}")
\t\t\t\ttry:
\t\t\t\t\timport frappe as _frappe
\t\t\t\t\t_frappe.db.rollback()
\t\t\t\texcept Exception:
\t\t\t\t\tpass
\t\t\telse:
\t\t\t\traise
"""

# 2. link-filters-json-list: Postgres returns the json column
#    DocField.link_filters already decoded (a list); MariaDB returns text.
#    validate_link_filters json.loads() it and throws "Filters must be valid
#    JSON" when rcore's fixtures add Custom Fields. Accept the list as is.
LINK_FILTERS_OLD = """\t\ttry:
\t\t\tlink_filters = json.loads(link_filters_value)
\t\texcept (TypeError, ValueError):
"""
LINK_FILTERS_NEW = """\t\ttry:
\t\t\t# ignition patch: Postgres returns the json column already decoded
\t\t\tlink_filters = (
\t\t\t\tlink_filters_value
\t\t\t\tif isinstance(link_filters_value, list)
\t\t\t\telse json.loads(link_filters_value)
\t\t\t)
\t\texcept (TypeError, ValueError):
"""

PATCHES = (
    ("fixtures-duplicate-key", "frappe/utils/fixtures.py", FIXTURES_OLD, FIXTURES_NEW),
    ("link-filters-json-list", "frappe/core/doctype/doctype/doctype.py",
     LINK_FILTERS_OLD, LINK_FILTERS_NEW),
)


def apply(frappe_dir, name, rel, old, new):
    path = os.path.join(frappe_dir, rel)
    with open(path, encoding="utf-8", newline="") as f:
        text = f.read()
    if text.count(new) == 1:
        return "already applied"
    if text.count(old) != 1:
        raise SystemExit("patch %s: expected text found %d times in %s (need exactly 1); "
                         "Frappe changed, update platform/scripts/patch_frappe_v16.py"
                         % (name, text.count(old), rel))
    text = text.replace(old, new)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    with open(path, encoding="utf-8", newline="") as f:
        done = f.read()
    if done.count(new) != 1:
        raise SystemExit("patch %s: %s did not take the change" % (name, rel))
    compile(done, path, "exec")  # a SyntaxError fails the build
    return "applied"


def main(argv):
    if len(argv) != 2 or not os.path.isdir(os.path.join(argv[1], "frappe")):
        raise SystemExit("usage: patch_frappe_v16.py <frappe checkout (apps/frappe)>")
    for name, rel, old, new in PATCHES:
        state = apply(argv[1], name, rel, old, new)
        print(name)
        print("[patch-frappe] %s: %s (%s)" % (name, state, rel), file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv)
