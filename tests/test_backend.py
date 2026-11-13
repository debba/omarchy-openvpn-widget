"""Unit tests for backend functions that do not touch NetworkManager."""

from argparse import Namespace
from importlib.machinery import SourceFileLoader
from pathlib import Path
from subprocess import CompletedProcess
import tempfile
import unittest
from unittest.mock import call, patch

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

    def test_import_uses_name_assigned_before_first_connection(self):
        path = Path("/tmp/office.ovpn")
        state = {str(path): {"name": "Main office"}}
        imported = {"vpn-uuid": {"uuid": "vpn-uuid", "name": "office", "type": "vpn"}}

        with (
            patch.object(module, "nm_connections", side_effect=[{}, imported]),
            patch.object(module, "run") as run,
            patch.object(module, "save_state") as save_state,
        ):
            record = module.ensure_imported(path, state)

        self.assertEqual(record, {"uuid": "vpn-uuid", "name": "Main office"})
        self.assertEqual(
            run.call_args_list,
            [
                call(["nmcli", "connection", "import", "type", "openvpn", "file", str(path)]),
                call(["nmcli", "connection", "modify", "uuid", "vpn-uuid", "connection.id", "Main office"]),
            ],
        )
        save_state.assert_called_once_with(state)

    def test_nm_active_states_maps_uuid_to_state(self):
        output = "uuid-a:activated\nuuid-b:activating\n\n"
        with patch.object(module, "run", return_value=CompletedProcess([], 0, output, "")):
            self.assertEqual(module.nm_active_states(), {"uuid-a": "activated", "uuid-b": "activating"})

    def test_list_reports_activating_profile_as_connecting_not_active(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "office.ovpn").touch()
            (root / "home.ovpn").touch()
            office, home = str((root / "office.ovpn").resolve()), str((root / "home.ovpn").resolve())
            state = {office: {"uuid": "uuid-office", "name": "Office"}, home: {"uuid": "uuid-home", "name": "Home"}}
            connections = {uuid: {"uuid": uuid, "name": uuid, "type": "vpn"} for uuid in ("uuid-office", "uuid-home")}

            with (
                patch.object(module, "load_state", return_value=state),
                patch.object(module, "nm_connections", return_value=connections),
                patch.object(module, "nm_active_states", return_value={"uuid-office": "activating", "uuid-home": "activated"}),
                patch.object(module, "secret_lookup", return_value=""),
                patch.object(module, "emit") as emit,
            ):
                module.command_list(Namespace(config_dir=directory))

        profiles = {profile["name"]: profile for profile in emit.call_args.args[0]["profiles"]}
        self.assertEqual((profiles["Office"]["active"], profiles["Office"]["connecting"]), (False, True))
        self.assertEqual((profiles["Home"]["active"], profiles["Home"]["connecting"]), (True, False))

    def test_failed_connect_brings_the_profile_down(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "office.ovpn"
            path.touch()

            def fake_run(command, **_kwargs):
                failed = command[:4] == ["nmcli", "--wait", str(module.CONNECT_TIMEOUT_SEC), "connection"]
                return CompletedProcess(command, 4 if failed else 0, "", "Error: Connection activation failed")

            with (
                patch.object(module, "secret_lookup", side_effect=lambda _path, field: field),
                patch.object(module, "load_state", return_value={}),
                patch.object(module, "ensure_imported", return_value={"uuid": "vpn-uuid", "name": "Office"}),
                patch.object(module, "run", side_effect=fake_run) as run,
            ):
                with self.assertRaisesRegex(module.WidgetError, "Connection failed"):
                    module.command_connect(Namespace(config=str(path)))

        self.assertIn(call(["nmcli", "connection", "down", "uuid", "vpn-uuid"], check=False), run.call_args_list)


if __name__ == "__main__":
    unittest.main()
