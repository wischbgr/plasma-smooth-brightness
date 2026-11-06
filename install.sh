#!/bin/bash
# Installs smooth-brightnessd as a systemd user service.
set -euo pipefail
cd "$(dirname "$0")"

BIN="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"

install -Dm755 smooth-brightnessd "$BIN/smooth-brightnessd"
install -Dm644 smooth-brightness.service "$UNIT_DIR/smooth-brightness.service"

systemctl --user daemon-reload
systemctl --user enable smooth-brightness.service
systemctl --user restart smooth-brightness.service
sleep 1
systemctl --user --no-pager status smooth-brightness.service | head -n 12
