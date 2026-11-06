#!/bin/bash
# Removes smooth-brightnessd; PowerDevil takes over the brightness keys again.
set -uo pipefail

systemctl --user disable --now smooth-brightness.service 2>/dev/null
# In case the service wasn't running: hand the keys back to PowerDevil anyway
[ -x "$HOME/.local/bin/smooth-brightnessd" ] && "$HOME/.local/bin/smooth-brightnessd" --restore
busctl --user call org.kde.kglobalaccel /kglobalaccel org.kde.KGlobalAccel \
  unregister ss smooth-brightness increase >/dev/null 2>&1
busctl --user call org.kde.kglobalaccel /kglobalaccel org.kde.KGlobalAccel \
  unregister ss smooth-brightness decrease >/dev/null 2>&1

rm -f "$HOME/.config/systemd/user/smooth-brightness.service" "$HOME/.local/bin/smooth-brightnessd"
systemctl --user daemon-reload
echo "smooth-brightness removed."
# A settings override (systemctl --user edit) is kept, if one exists:
[ -d "$HOME/.config/systemd/user/smooth-brightness.service.d" ] && \
  echo "Kept settings override: ~/.config/systemd/user/smooth-brightness.service.d/"
exit 0
