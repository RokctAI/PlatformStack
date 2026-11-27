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
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import site_env  # noqa: E402

ENV = (
    "STICKS_NAME=Sticks\r\nSTICKS_IOS_PACKAGE_NAME=work.sticks.app\r\n"
    "SUPACHARGE_APP_NAME=Supacharge\r\nGOOGLE_MAPS_API_KEY=k\r\n"
    "##########END_FLUTTER##########\r\n"
    "# WebApp Native Public Endpoints\r\n"
    "NEXT_PUBLIC_DYNAMIC_LINK_IOS_BUNDLE_ID=${APP_IOS_PACKAGE_NAME}\r\n"
    "NEXT_PUBLIC_SITE_NAME=${APP_NAME}\r\n"
    "NEXT_PUBLIC_MAP_API_KEY=${GOOGLE_MAPS_API_KEY}\r\n"
    "NEXT_PUBLIC_WEBSITE_URL=${APP_SITE_URL}\r\n"
    "NEXT_PUBLIC_EMPTY=\r\n"
    "NEXT_PUBLIC_LEAK=${DB_ROOT_PASSWORD}\r\n"
    "##########END_NEXTJS##########\r\n"
    "DB_ROOT_PASSWORD=secret\r\n"
)


class SiteEnvTest(unittest.TestCase):
    def setUp(self):
        self.values, self.block = site_env.parse(ENV)

    def test_app_placeholders_follow_the_site(self):
        out = site_env.render({"name": "sticks", "app": "STICKS", "domains": ["usesticks.com"]}, self.values, self.block)
        self.assertIn("NEXT_PUBLIC_DYNAMIC_LINK_IOS_BUNDLE_ID=work.sticks.app\n", out)
        self.assertIn("NEXT_PUBLIC_SITE_NAME=Sticks\n", out)
        self.assertIn("NEXT_PUBLIC_WEBSITE_URL=https://usesticks.com\n", out)
        self.assertIn("NEXT_PUBLIC_MAP_API_KEY=k\n", out)

    def test_app_name_falls_back_to_app_app_name(self):
        out = site_env.render({"name": "supacharge", "app": "SUPACHARGE", "domains": ["supacharge.school"]}, self.values, self.block)
        self.assertIn("NEXT_PUBLIC_SITE_NAME=Supacharge\n", out)

    def test_empty_values_and_other_sections_are_left_out(self):
        out = site_env.render({"name": "hosting", "domains": ["cortexagency.co"]}, self.values, self.block)
        self.assertNotIn("DYNAMIC_LINK", out)
        self.assertNotIn("NEXT_PUBLIC_EMPTY", out)
        self.assertNotIn("DB_ROOT_PASSWORD", out)
        self.assertNotIn("NEXT_PUBLIC_LEAK", out)
        self.assertIn("NEXT_PUBLIC_WEBSITE_URL=https://cortexagency.co\n", out)


if __name__ == "__main__":
    unittest.main()
