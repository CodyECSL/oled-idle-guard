# oled-idle-guard

**Lock and blank your screen on real inactivity — even while a game is running —
and treat a game controller as activity so it doesn't fire while you're playing.**

On KDE Plasma (Wayland), the built-in dimming, "turn off screen", and auto-lock
all stop working the moment a full-screen game (or Steam) grabs an *idle
inhibitor*. And the compositor never sees gamepad input at all, so a controller
neither keeps the screen awake nor counts as "you're still here". The result on
an OLED panel is either burn-in risk (screen stays on for hours untouched) or a
screen that blanks mid-game when you're playing with a pad.

`oled-idle-guard` fixes both. A small root daemon reads the raw input devices
directly — keyboards, mice, touchpads **and** gamepads — keeps its own activity
clock, and drives the dim / lock / screen-off itself, ignoring inhibitors:

| after this long with **no** keyboard / mouse / gamepad input | what happens |
|---|---|
| `DIM_TIMEOUT` (default 2 min) | every display dims to `DIM_BRIGHTNESS`% |
| `LOCK_TIMEOUT` (default 5 min) | session locks **and** panels go to DPMS-off — true black, zero OLED emission |
| any input | brightness and panels restored (does **not** unlock) |
| locked, screen woken by a pad button, then idle `RELOCK_BLANK_SEC` (default 1 min) | blanks again, so the lock screen can't burn in |
| you unlock (password) | back to normal |

It also blanks after a manual lock (Meta+L) once you stop touching input, and
comes up locked + blank after resume from suspend.

A **system-tray indicator** (`oled-idle-guard-tray`) shows the live countdowns,
pulses when it detects input, has per-device activity lights, and lets you
change the timeouts, snooze the guard, or lock immediately — no root needed.

Built for KDE Plasma 6 on Wayland (KWin). Arch / CachyOS packaging; adaptable
to other distros.

---

## Installation

Everything installs from this repo with one script. It needs `sudo` because the
daemon runs as root (see [Security](#security)).

**1. Get the code**

```bash
git clone git@github.com:CodyECSL/oled-idle-guard.git
cd oled-idle-guard
```

**2. Look at what you're about to run as root** (optional but sensible)

```bash
less install.sh oled-idle-guard oled-idle-guard-tray
```

**3. Run the installer**

```bash
sudo ./install.sh
```

This will:

- install any missing packages (`python-evdev`, `kscreen`, `util-linux`, and
  `pyside6` for the tray) with `pacman`;
- install the daemon to `/usr/local/bin` and its unit to
  `/etc/systemd/system/oled-idle-guard.service`, then **enable + start** it;
- install the tray app and a per-user unit, enable it for all users, and start
  it in your current session;
- write `/etc/oled-idle-guard.conf` with your desktop user's id filled in;
- turn **off** KDE's own "Dim screen" and "Turn off screen" (both AC and
  battery) so PowerDevil doesn't fight the daemon over brightness. Auto-lock is
  left **on** as a backstop.

  Flags: `--no-tray` (daemon only), `--no-kde-tweaks` (leave KDE power settings
  alone).

**4. Check it's running**

```bash
systemctl status oled-idle-guard
journalctl -fu oled-idle-guard
```

The log lists every input device it's watching at startup. Press keys / move the
mouse / press a gamepad button and confirm they show up (run with `DEBUG=1` in
the config for per-event logging while testing).

**5. Try it**

Temporarily set short timeouts to watch the whole cycle, either in the tray's
**Timeouts** panel or in `/etc/oled-idle-guard.conf` (then
`sudo systemctl restart oled-idle-guard`). You should see the screen dim, then
lock and go black; any input restores it.

### Updating

```bash
git pull
sudo ./install.sh
```

The installer restarts the daemon so the new version takes over.

### Uninstalling

```bash
sudo /usr/local/share/doc/oled-idle-guard/uninstall.sh
```

Removes the binaries and units, stops both services, and prints how to turn
KDE's own dimming back on. Your `/etc/oled-idle-guard.conf` is left in place.

---

## Configuration

Timings can be set two ways, and they stack — the override wins:

1. **Base values** — edit `/etc/oled-idle-guard.conf`, then
   `sudo systemctl restart oled-idle-guard`:

   | key | meaning | default |
   |---|---|---|
   | `DIM_TIMEOUT` | seconds idle before dimming | 120 |
   | `LOCK_TIMEOUT` | seconds idle before lock + blank | 300 |
   | `RELOCK_BLANK_SEC` | while locked, re-blank after this idle | 60 |
   | `DIM_BRIGHTNESS` | brightness % when dimmed | 15 |
   | `ABS_THRESHOLD_FRAC` | gamepad stick movement below this fraction of range is ignored (drift) | 0.10 |
   | `DEBUG` | `1` logs every input event to the journal | 0 |

2. **Live, from the tray** — the **Timeouts** panel in the activity monitor has
   spin boxes for *Dim after*, *Lock + black after*, *Re-blank when locked* and
   *Dim to* (%). **Apply** changes them immediately (no restart, no root) and
   the daemon persists them to `/var/lib/oled-idle-guard/overrides.json`, which
   takes precedence over the `.conf` and survives restarts. **Reset to config
   file** deletes the override. The panel footer says whether the running values
   match the config file or an override.

---

## The tray indicator

`oled-idle-guard-tray` (PySide6) runs as a **user** service and appears in the
Plasma system tray.

- **Icon** — colour by state: green active · amber dimmed · red locked · blue-grey
  snoozed · grey = daemon down. A ring fills as the lock countdown runs; a white
  dot pulses whenever input is detected.
- **Hover** — `dim in M:SS · lock in M:SS`, or the snooze end time.
- **Click** — opens the **activity monitor**: large dim / lock countdowns,
  per-kind indicator lights (Keyboard / Mouse / Gamepad) that flash on input,
  last-input device and age, the editable **Timeouts** panel, the list of
  watched devices, a scrolling event log, and **Snooze** / **Lock + blank now**
  buttons.
- **Right-click menu** — Snooze 15 m / 30 m / 1 h / 2 h, Cancel snooze,
  Lock + blank now.

Snoozing suppresses dimming and locking for the chosen period (a long cut-scene,
AFK farming) and is shown on the icon.

---

## How it works

Plasma's dimming (PowerDevil), "turn off screen", and auto-lock (KScreenLocker)
learn that you're idle from KWin's idle-notify protocol (`KIdleTime`). KWin
**pauses that protocol whenever any client holds an idle inhibitor** — the
Wayland `idle-inhibit` protocol or the `org.freedesktop.ScreenSaver` /
`PowerManagement.Inhibit` D-Bus calls — which nearly every full-screen game and
Steam do. So none of those features fire during a game. Gamepads are also not
part of the compositor's input, so they don't reset the idle clock or keep the
screen awake even when nothing is inhibiting.

`oled-idle-guard` doesn't use any of that. It:

- opens every `/dev/input/event*` device that reports keys, relative motion, or
  absolute axes, and re-scans for hot-plugged ones every few seconds;
- treats a key, a pointer move, or a large-enough axis move (stick-drift
  filtered) as activity and stamps its own monotonic clock;
- on its own timers, calls `kscreen-doctor` (brightness, DPMS) and
  `loginctl lock-session` in the desktop user's session via `runuser`;
- keeps working regardless of inhibitors, because it never asks the compositor
  anything.

When Steam Input is active it grabs the physical pad and exposes a virtual one
(`Microsoft X-Box 360 pad` / `Steam Virtual Gamepad`); the guard watches that
too, so remapped input still counts.

### Components and files

| path | purpose |
|---|---|
| `/usr/local/bin/oled-idle-guard` | the daemon (Python + `python-evdev`), runs as root |
| `/etc/systemd/system/oled-idle-guard.service` | daemon unit |
| `/etc/oled-idle-guard.conf` | base configuration |
| `/var/lib/oled-idle-guard/overrides.json` | live timeout changes from the tray; wins over the `.conf` |
| `/usr/local/bin/oled-idle-guard-tray` | the tray indicator (PySide6) |
| `/etc/systemd/user/oled-idle-guard-tray.service` | tray unit (per user) |
| `/run/oled-idle-guard.state` | live status JSON (daemon → tray) + saved brightness |
| `$XDG_RUNTIME_DIR/oled-idle-guard.cmd` | command channel (tray → daemon) |

### IPC

The daemon writes `/run/oled-idle-guard.state` (world-readable JSON) about four
times a second: state, idle seconds, countdowns, current timeouts, watched
devices, last input.

The tray writes one command per line to `$XDG_RUNTIME_DIR/oled-idle-guard.cmd`;
the daemon reads and deletes it each tick:

```
snooze <unix-epoch>       suppress dim/lock until that time
resume                    cancel a snooze
lock                      lock + blank now
wake                      count as activity now
set-dim <seconds>         change + persist the dim timeout
set-lock <seconds>        change + persist the lock+blank timeout
set-relock <seconds>      change + persist the re-blank-while-locked timeout
set-dim-brightness <pct>  change + persist the dim brightness
reset-config              discard overrides.json, revert to the conf file
```

---

## Interaction with KDE's own settings

The installer sets `DimDisplayWhenIdle=false` and `TurnOffDisplayWhenIdle=false`
in `powerdevilrc` (AC and battery) so PowerDevil doesn't also drive brightness.
**Auto-lock is left on** as a backstop for when the daemon isn't running. Turn
KDE's dimming back on any time in *System Settings → Power Management*, or run
`install.sh --no-kde-tweaks` to never touch those settings.

---

## Troubleshooting

**A timeout change in the tray snaps back to the old value** — the running
daemon is an old version that predates the `set-*` commands. `sudo systemctl
restart oled-idle-guard` (or re-run `install.sh`, which does this for you).

**The tray icon is missing** — `systemctl --user status oled-idle-guard-tray`.
It needs `pyside6` and a running Plasma tray host; it retries at startup.

**A gamepad isn't detected** — press a button (it hot-plug-rescans) and check
`journalctl -fu oled-idle-guard` for a `watching … [gamepad]` line. If Steam
Input has an exclusive grab, the guard follows the virtual pad instead.

**It locked/dimmed while I was using a controller** — check the controller
appears in the watched-devices list, and that stick drift isn't the only signal
(button presses always count). Raise `ABS_THRESHOLD_FRAC` if a worn stick keeps
the screen awake instead.

---

## Requirements

- KDE Plasma 6 on Wayland (KWin)
- `python` ≥ 3.9, `python-evdev`
- `kscreen` (`kscreen-doctor`), `util-linux` (`runuser`), `systemd`
- `pyside6` for the tray (optional — `install.sh --no-tray` skips it)

---

## Security

The daemon runs as **root** on purpose: during a game the compositor won't
report keyboard/mouse idle, so reading the raw `/dev/input` streams is the only
reliable source, and that needs root (or the `input` group / a udev rule, which
would let *any* of your processes keylog — this design avoids that). It shells
out to your session only for `kscreen-doctor` and `loginctl`, and `/dev/input`
permissions are left untouched. The tray runs unprivileged and only reads a
status file and writes a command file in your own runtime directory.

---

## License

MIT — see [LICENSE](LICENSE).
