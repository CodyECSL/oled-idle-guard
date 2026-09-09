#!/usr/bin/env bash
#
# Installer for oled-idle-guard.
#
#   sudo ./install.sh                 # daemon + tray + disable PowerDevil dim/off
#   sudo ./install.sh --no-kde-tweaks # don't touch KDE power settings
#   sudo ./install.sh --no-tray       # daemon only, skip the tray indicator
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KDE_TWEAKS=1
TRAY=1
for a in "$@"; do
    case "$a" in
        --no-kde-tweaks) KDE_TWEAKS=0 ;;
        --no-tray)       TRAY=0 ;;
        *) echo "unknown option: $a" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "run me with sudo" >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# figure out the desktop user (active graphical session on seat0)
# --------------------------------------------------------------------------- #
DESK_UID=""
while read -r sid uid _; do
    seat=$(loginctl show-session "$sid" -p Seat --value 2>/dev/null || true)
    typ=$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)
    if [[ "$seat" == "seat0" && ( "$typ" == "wayland" || "$typ" == "x11" ) ]]; then
        DESK_UID="$uid"
        break
    fi
done < <(loginctl list-sessions --no-legend)

if [[ -z "$DESK_UID" ]]; then
    # fall back to the first "normal" (uid >= 1000) human user with a runtime dir
    for d in /run/user/*; do
        u=${d##*/}
        [[ "$u" -ge 1000 ]] && { DESK_UID="$u"; break; }
    done
fi
[[ -z "$DESK_UID" ]] && { echo "could not determine the desktop user" >&2; exit 1; }
DESK_USER="$(id -nu "$DESK_UID")"
echo "desktop user : $DESK_USER ($DESK_UID)"

# --------------------------------------------------------------------------- #
# dependencies
# --------------------------------------------------------------------------- #
missing=()
command -v kscreen-doctor >/dev/null || missing+=("kscreen")
command -v runuser        >/dev/null || missing+=("util-linux")
command -v loginctl       >/dev/null || missing+=("systemd")
python3 -c 'import evdev' 2>/dev/null || missing+=("python-evdev")
if (( TRAY )); then
    python3 -c 'import PySide6' 2>/dev/null || missing+=("pyside6")
fi
if (( ${#missing[@]} )); then
    echo "installing missing packages: ${missing[*]}"
    pacman -S --needed --noconfirm "${missing[@]}"
fi

# --------------------------------------------------------------------------- #
# install files
# --------------------------------------------------------------------------- #
install -Dm0755 "$SRC/oled-idle-guard"          /usr/local/bin/oled-idle-guard
install -Dm0644 "$SRC/oled-idle-guard.service"  /etc/systemd/system/oled-idle-guard.service
install -Dm0644 "$SRC/README.md"                /usr/local/share/doc/oled-idle-guard/README.md
install -Dm0755 "$SRC/uninstall.sh"             /usr/local/share/doc/oled-idle-guard/uninstall.sh

if (( TRAY )); then
    install -Dm0755 "$SRC/oled-idle-guard-tray"         /usr/local/bin/oled-idle-guard-tray
    install -Dm0644 "$SRC/oled-idle-guard-tray.service" /etc/systemd/user/oled-idle-guard-tray.service
else
    rm -f /usr/local/bin/oled-idle-guard-tray /etc/systemd/user/oled-idle-guard-tray.service
fi

if [[ -f /etc/oled-idle-guard.conf ]]; then
    echo "keeping existing /etc/oled-idle-guard.conf (new template -> .conf.new)"
    install -Dm0644 "$SRC/oled-idle-guard.conf" /etc/oled-idle-guard.conf.new
    sed -i "s/^GUARD_UID=.*/GUARD_UID=$DESK_UID/; s/^GUARD_USER=.*/GUARD_USER=$DESK_USER/" \
        /etc/oled-idle-guard.conf.new
else
    install -Dm0644 "$SRC/oled-idle-guard.conf" /etc/oled-idle-guard.conf
    sed -i "s/^GUARD_UID=.*/GUARD_UID=$DESK_UID/; s/^GUARD_USER=.*/GUARD_USER=$DESK_USER/" \
        /etc/oled-idle-guard.conf
fi

# --------------------------------------------------------------------------- #
# stop PowerDevil from also dimming / blanking (it can't do it during games
# anyway, and when it can it fights this daemon over brightness)
# --------------------------------------------------------------------------- #
if (( KDE_TWEAKS )); then
    if command -v kwriteconfig6 >/dev/null; then
        for profile in AC Battery; do
            runuser -u "$DESK_USER" -- kwriteconfig6 --file powerdevilrc \
                --group "$profile" --group Display --key DimDisplayWhenIdle false
            runuser -u "$DESK_USER" -- kwriteconfig6 --file powerdevilrc \
                --group "$profile" --group Display --key TurnOffDisplayWhenIdle false
        done
        # nudge PowerDevil to reload (harmless if the bus call fails)
        runuser -u "$DESK_USER" -- env \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$DESK_UID/bus" \
            qdbus6 org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement \
            refreshStatus 2>/dev/null || true
        echo "PowerDevil: automatic dim + turn-off-screen disabled (auto-lock left ON)"
    else
        echo "kwriteconfig6 not found -- disable 'Dim screen' and 'Turn off screen'"
        echo "manually in System Settings > Power Management."
    fi
fi

# --------------------------------------------------------------------------- #
# enable  (restart, not just "enable --now" -- an already-running old copy
#          would otherwise keep going after a re-install)
# --------------------------------------------------------------------------- #
systemctl daemon-reload
systemctl enable oled-idle-guard.service
systemctl restart oled-idle-guard.service

if (( TRAY )); then
    systemctl --global enable oled-idle-guard-tray.service
    # start it now in the running session too
    runuser -u "$DESK_USER" -- env \
        XDG_RUNTIME_DIR="/run/user/$DESK_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$DESK_UID/bus" \
        systemctl --user daemon-reload 2>/dev/null || true
    runuser -u "$DESK_USER" -- env \
        XDG_RUNTIME_DIR="/run/user/$DESK_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$DESK_UID/bus" \
        systemctl --user restart oled-idle-guard-tray.service 2>/dev/null \
        && echo "tray indicator started" \
        || echo "tray indicator will appear on next login"
fi

sleep 1
systemctl --no-pager --full status oled-idle-guard.service || true

cat <<EOF

installed.

  timings      /etc/oled-idle-guard.conf   (then: sudo systemctl restart oled-idle-guard)
  daemon log   journalctl -fu oled-idle-guard
  tray log     journalctl --user -fu oled-idle-guard-tray
  uninstall    sudo /usr/local/share/doc/oled-idle-guard/uninstall.sh

The tray icon shows state + countdowns; click it for the activity monitor
(per-device input lights, live log, snooze / lock-now buttons).
EOF
