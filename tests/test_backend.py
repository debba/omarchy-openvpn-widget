"""Unit tests for backend functions that do not touch NetworkManager."""

from argparse import Namespace
from importlib.machinery import SourceFileLoader
from pathlib import Path
from subprocess import CompletedProcess
import io
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
                    module.command_connect(Namespace(config=str(path), password_stdin=False))

        self.assertIn(call(["nmcli", "connection", "down", "uuid", "vpn-uuid"], check=False), run.call_args_list)


    def test_save_credentials_in_ask_password_mode_keeps_only_the_username(self):
        with tempfile.TemporaryDirectory() as directory:
            path = (Path(directory) / "office.ovpn")
            path.touch()
            state = {}
            payload = '{"username": "alice", "password": "", "askPassword": true}\n'
            with (
                patch.object(module.sys, "stdin", io.StringIO(payload)),
                patch.object(module, "load_state", return_value=state),
                patch.object(module, "save_state"),
                patch.object(module, "secret_store") as secret_store,
                patch.object(module, "secret_clear") as secret_clear,
                patch.object(module, "emit") as emit,
            ):
                module.command_save_credentials(Namespace(config=str(path)))

        secret_store.assert_called_once_with(path.resolve(), "username", "alice")
        secret_clear.assert_called_once_with(path.resolve(), "password")
        self.assertTrue(state[str(path.resolve())]["askPassword"])
        self.assertTrue(emit.call_args.args[0]["askPassword"])

    def test_save_credentials_requires_a_password_unless_asked_each_time(self):
        with patch.object(module.sys, "stdin", io.StringIO('{"username": "alice", "password": ""}\n')):
            with self.assertRaisesRegex(module.WidgetError, "password are required"):
                module.read_credentials()

    def _connect(self, directory, state, password_stdin, stdin=""):
        path = Path(directory) / "office.ovpn"
        path.touch()
        key = str(path.resolve())
        written = []

        def fake_run(command, **_kwargs):
            if "passwd-file" in command:
                written.append(Path(command[-1]).read_text())
            return CompletedProcess(command, 0, "", "")

        with (
            patch.object(module.sys, "stdin", io.StringIO(stdin)),
            patch.object(module, "secret_lookup", side_effect=lambda _path, field: f"stored-{field}"),
            patch.object(module, "load_state", return_value={key: state} if state else {}),
            patch.object(module, "ensure_imported", return_value={"uuid": "vpn-uuid", "name": "Office"}),
            patch.object(module, "run", side_effect=fake_run),
            patch.object(module, "emit"),
        ):
            module.command_connect(Namespace(config=str(path), password_stdin=password_stdin))
        return written

    def test_connect_uses_password_from_stdin(self):
        with tempfile.TemporaryDirectory() as directory:
            written = self._connect(directory, {"askPassword": True}, True, '{"password": "123456"}\n')
        self.assertEqual(written, ["vpn.secrets.password:123456\n"])

    def test_connect_never_replays_a_stored_password_in_ask_password_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(module.WidgetError, "password is required"):
                self._connect(directory, {"askPassword": True}, False)

    def test_connect_uses_keyring_password_by_default(self):
        with tempfile.TemporaryDirectory() as directory:
            written = self._connect(directory, {}, False)
        self.assertEqual(written, ["vpn.secrets.password:stored-password\n"])


if __name__ == "__main__":
    unittest.main()
