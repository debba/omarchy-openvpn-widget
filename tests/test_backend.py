"""Unit tests for backend functions that do not touch NetworkManager."""

from importlib.machinery import SourceFileLoader
from pathlib import Path
import tempfile
import unittest

BACKEND = Path(__file__).parents[1] / "scripts" / "openvpn-widget"
module = SourceFileLoader("openvpn_widget", str(BACKEND)).load_module()


class BackendTests(unittest.TestCase):
    def test_parse_terse_line_unescapes_colons_and_backslashes(self):
        self.assertEqual(
            module.parse_terse_line(r"uuid:Name\: office:vpn\\type"),
            ["uuid", "Name: office", "vpn\\type"],
        )

    def test_discover_returns_supported_files_in_name_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Zurich.ovpn").touch()
            (root / "amsterdam.conf").touch()
            (root / "ignore.txt").touch()
            self.assertEqual(
                [item.name for item in module.discover(root)],
                ["amsterdam.conf", "Zurich.ovpn"],
            )

    def test_config_key_is_stable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "vpn.ovpn"
            path.touch()
            self.assertEqual(module.config_key(path), module.config_key(path.resolve()))
            self.assertEqual(len(module.config_key(path)), 64)


if __name__ == "__main__":
    unittest.main()
