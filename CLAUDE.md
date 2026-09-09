# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Two cooperating processes that lock/dim/blank a KDE Plasma (Wayland) screen on
real inactivity even while a game holds an idle inhibitor, counting gamepad
input as activity. Target: Plasma 6 / KWin on Arch / CachyOS. There is no build
system, no package, no test framework — the deliverables are the scripts
themselves plus `install.sh`.

- `oled-idle-guard` — the daemon. Python + `python-evdev`, **runs as root**
  (systemd system service). Reads raw `/dev/input/event*`, keeps its own idle
  clock, and drives `kscreen-doctor` / `loginctl` in the user session via
  `runuser`.
- `oled-idle-guard-tray` — the indicator. Python + **PySide6**, runs as an
  unprivileged systemd *user* service. Pure viewer + command sender.

## Working on it

```bash
# syntax check (there are no tests)
python3 -m py_compile oled-idle-guard oled-idle-guard-tray
bash -n install.sh uninstall.sh

# install / update on a real machine (restarts the daemon)
sudo ./install.sh                 # daemon + tray
sudo ./install.sh --no-tray       # daemon only
sudo ./install.sh --no-kde-tweaks # don't touch powerdevilrc

# watch it run
journalctl -fu oled-idle-guard              # daemon
journalctl --user -fu oled-idle-guard-tray  # tray
```

The daemon **cannot be meaningfully run outside root** (it gets zero input
devices without `/dev/input` access, and `runuser` refuses non-root). To
exercise logic without installing, copy the file and rewrite the hard-coded
paths, then feed it env + a fake command file:

```bash
sed 's#/run/oled-idle-guard.state#/tmp/t/state.json#;
     s#f"/run/user/{UID}/oled-idle-guard.cmd"#"/tmp/t/cmd"#;
     s#"/var/lib/oled-idle-guard"#"/tmp/t/lib"#' oled-idle-guard > /tmp/t/daemon.py
GUARD_UID=1000 GUARD_USER=$USER DIM_TIMEOUT=3 LOCK_TIMEOUT=6 DEBUG=1 python3 /tmp/t/daemon.py
```

The tray can be unit-tested headless: install PySide6 in a venv, run with
`QT_QPA_PLATFORM=offscreen`, import the module, construct `Tray(app)`, write
synthetic status JSON to its `STATE_FILE`, and call `tray.tick()`. This is how
the config-panel and state-transition behaviour was verified.

## Architecture

### The core constraint (why it's built this way)

Plasma's dimming/lock/screen-off all detect idleness through KWin's idle-notify
protocol, which **KWin suspends whenever any client holds an idle inhibitor** —
every full-screen game does this. And gamepads are not compositor input at all.
So the daemon must (a) bypass the compositor entirely and read evdev directly,
which requires root, and (b) feed gamepad events into the same activity clock as
keyboard/mouse. Every design choice follows from this. Do not replace the evdev
reader with `swayidle`, `ext-idle-notify`, or any compositor idle API — they all
inherit the inhibitor problem.

### IPC — two files, no sockets

| file | direction | format | rate |
|---|---|---|---|
| `/run/oled-idle-guard.state` | daemon → tray | one JSON object (atomic `os.replace`) | ~4 Hz, and immediately on input |
| `$XDG_RUNTIME_DIR/oled-idle-guard.cmd` | tray → daemon | one command per line; daemon reads then `unlink`s | on user action |

`time.monotonic()` is CLOCK_MONOTONIC (system-wide on Linux) so both processes
compare it directly, but the status JSON also carries wall-clock `ts` and
pre-computed `dim_in`/`lock_in` so the tray never has to.

Command vocabulary lives in one place: the `for cmd in read_commands()` loop in
the daemon's `main()`. The tray's `send_command()` must stay in sync with it.

### Daemon (`oled-idle-guard`)

- `InputWatcher` — opens every evdev device with EV_KEY/EV_REL/EV_ABS, re-scans
  for hotplug on a timer, classifies each device (`_classify` → keyboard / mouse
  / touchpad / gamepad / other, from capability bits), applies a per-axis
  drift threshold to EV_ABS so a worn stick can't hold the screen awake.
- `main()` is a single ~1 s loop. States: `active → dimmed → locked-blank`, plus
  a snooze that forces "awake". Notable edges the loop already handles: external
  lock (Meta+L), suspend/resume (wall-clock jump), lock-never-confirmed retry
  (`seen_locked` / `LOCK_CONFIRM_GRACE`), re-blank while locked.
- `Cfg` — the four tunables (`dim`, `lock`, `relock`, `dim_brightness`).
  Precedence: module-level constants (from the EnvironmentFile) → `overrides.json`
  → live `set-*` commands, persisted back to
  `$STATE_DIRECTORY/overrides.json`. **The loop reads `cfg.*`, never the
  `DIM_TIMEOUT` etc. constants** — those are only defaults for `Cfg`.
- Everything KDE-facing goes through `run_as_user()` →
  `runuser --whitelist-environment=... -u $USER -- <cmd>` with a reconstructed
  Wayland/D-Bus environment. `kscreen-doctor` needs `WAYLAND_DISPLAY` +
  `XDG_RUNTIME_DIR`; `loginctl lock-session` is called directly as root.

### Tray (`oled-idle-guard-tray`)

- `Tray` owns the `QSystemTrayIcon`, a `QTimer` polling `read_status()` every
  250 ms, dynamic `render_icon()` (colour = state, ring = lock progress, dot =
  recent input), and the menu.
- `MonitorWindow` is the click-through window. The **Timeouts** panel edits
  `cfg` via `set-*` commands. Its sync logic is deliberate: `sync_cfg()` pushes
  daemon values into the spin boxes *unless* the user is mid-edit
  (`_cfg_dirty` / focus / `_apply_grace`), and after Apply it waits for the
  daemon to echo the new values (`_pending`) before showing "applied ✓" — or a
  "restart the daemon" warning if it never does. When touching this, keep the
  invariant that a heartbeat can never overwrite a value the user is editing.

### systemd units

- `oled-idle-guard.service` — `User=root`, `StateDirectory=oled-idle-guard`
  (creates/owns `/var/lib/oled-idle-guard`), loose sandboxing because it has to
  `setuid` into the user and reach `$HOME` + the session bus.
- `oled-idle-guard-tray.service` — installed to `/etc/systemd/user/`, enabled
  with `systemctl --global enable`, `WantedBy=graphical-session.target`.
- `install.sh` must **`systemctl restart`** the daemon, not `enable --now` — an
  already-running old copy otherwise survives an upgrade and silently ignores
  new commands.

## Conventions

- Both Python files are single-file, stdlib + one third-party dep each, no
  package layout. Keep them runnable as plain scripts.
- Match the existing style: module-level constants in a block, small free
  functions, `# noqa: BLE001` on the deliberate broad `except` around
  subprocess/D-Bus calls (this daemon must never crash on a transient session
  error).
- User-visible strings say "lock + black/blank" and "dim"; keep that wording
  consistent across daemon logs, tray, README, and `oled-idle-guard.conf`.
