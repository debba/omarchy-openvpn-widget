#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="community.openvpn"
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DESTINATION="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID"

echo "Installing OpenVPN and NetworkManager integration..."
omarchy pkg add openvpn networkmanager networkmanager-openvpn libsecret gnome-keyring

if [[ "$SOURCE_DIR" != "$DESTINATION" ]]; then
  mkdir -p "$(dirname "$DESTINATION")"
  if [[ -e "$DESTINATION" ]]; then
    backup="${DESTINATION}.backup.$(date +%s)"
    mv "$DESTINATION" "$backup"
    echo "Existing plugin backed up to $backup"
  fi
  cp -a "$SOURCE_DIR" "$DESTINATION"
fi

chmod +x "$DESTINATION/scripts/openvpn-widget"
omarchy plugin validate "$DESTINATION"
omarchy plugin enable "$PLUGIN_ID" --section right

echo "OpenVPN Manager installed. Configure its directory from the Omarchy bar settings."
