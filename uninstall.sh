#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "run me with sudo" >&2; exit 1; }

# stop the tray for any logged-in user, then disable globally
systemctl --global disable oled-idle-guard-tray.service 2>/dev/null || true
for d in /run/user/*; do
    u=${d##*/}
    runuser -u "$(id -nu "$u" 2>/dev/null || echo root)" -- env \
        XDG_RUNTIME_DIR="/run/user/$u" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$u/bus" \
        systemctl --user stop oled-idle-guard-tray.service 2>/dev/null || true
done

systemctl disable --now oled-idle-guard.service 2>/dev/null || true

rm -f /usr/local/bin/oled-idle-guard
rm -f /usr/local/bin/oled-idle-guard-tray
rm -f /etc/systemd/system/oled-idle-guard.service
rm -f /etc/systemd/user/oled-idle-guard-tray.service
rm -f /etc/oled-idle-guard.conf.new
rm -f /run/oled-idle-guard.state
rm -rf /usr/local/share/doc/oled-idle-guard
systemctl daemon-reload

echo "removed. /etc/oled-idle-guard.conf left in place (delete it yourself if you want)."
echo
echo "to re-enable KDE's own dimming / screen-off, turn them back on in"
echo "System Settings > Power Management, or run as your user:"
echo "  kwriteconfig6 --file powerdevilrc --group AC --group Display --key DimDisplayWhenIdle true"
echo "  kwriteconfig6 --file powerdevilrc --group AC --group Display --key TurnOffDisplayWhenIdle true"
