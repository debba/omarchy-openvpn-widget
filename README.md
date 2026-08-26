# OpenVPN Manager for Omarchy

A native Omarchy/Quickshell bar widget for importing and controlling OpenVPN profiles through NetworkManager.

## Features

- Discovers `.ovpn` and `.conf` files in a configurable directory.
- Imports profiles into NetworkManager only when they are first used.
- Connects and disconnects VPNs from the top-right bar.
- Stores usernames and passwords in the desktop Secret Service keyring through `secret-tool`.
- Never puts passwords in command-line arguments or in `shell.json`.
- Removes its temporary NetworkManager password file immediately after activation.
- Supports Omarchy's widget settings and theme components.

## Requirements

- Omarchy with the current Quickshell-based shell plugin API
- NetworkManager
- OpenVPN and `networkmanager-openvpn`
- `libsecret` and an active Secret Service provider such as GNOME Keyring

## Install from a clone

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/omarchy-openvpn-widget.git
cd omarchy-openvpn-widget
./install.sh
```

The installer uses `omarchy pkg add`, validates the plugin, and places it in the right section of the bar. It may ask for your administrator password.

## Install through the Omarchy plugin manager

Once this repository has a public GitHub URL:

```bash
omarchy pkg add openvpn networkmanager networkmanager-openvpn libsecret gnome-keyring
omarchy plugin add https://github.com/YOUR_GITHUB_USERNAME/omarchy-openvpn-widget.git --enable
```

If needed, place it explicitly:

```bash
omarchy bar move community.openvpn --section right
```

## Configuration

1. Put your provider files in `~/.config/openvpn`, or open the Omarchy bar settings and set **OpenVPN configuration directory** for this widget.
2. Open the shield icon in the bar.
3. Select a profile.
4. Enter its username and password. They are saved in the system keyring.
5. Select the profile again to disconnect or reconnect.

The directory is scanned non-recursively. Certificate and key paths referenced by an OpenVPN file must remain valid after NetworkManager imports it.

## Credential handling

Credentials are stored as Secret Service items with these attributes:

- `service=omarchy-openvpn-widget`
- `config=<SHA-256 of the canonical configuration path>`
- `field=username` or `field=password`

The state file at `~/.local/state/omarchy-openvpn-widget/profiles.json` contains only configuration paths, NetworkManager UUIDs, and display names. It does not contain credentials.

Selecting the trash action beside a profile removes both the imported NetworkManager connection and matching keyring items. The original `.ovpn`/`.conf` file is never modified or deleted.

## Development

```bash
python -m unittest discover -s tests -v
omarchy plugin validate .
```

For live development, link the repository into the user plugin directory and rescan:

```bash
ln -s "$PWD" ~/.config/omarchy/plugins/community.openvpn
omarchy-shell shell rescanPlugins
omarchy plugin enable community.openvpn --section right
```

## Uninstall

```bash
./uninstall.sh
```

Package removal is intentionally left to the user because OpenVPN and NetworkManager may be used by other applications.

## License

MIT
