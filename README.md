# System Toolbox

A lightweight [KDE Plasma 6](https://kde.org/plasma-desktop/) widget for everyday
system tools — starting with a keep-awake timer **and** ThinkPad fan
monitor/control — straight from the panel, **without any Python**.

It pairs a small QML plasmoid (two tabs: **Timer** and **Fan**) with a native
C++/Qt6 D-Bus helper for the timer plus three small audited bash helpers for the
fan. The timer helper is launched only while inhibition is active; the fan holder
runs only while a manual level is pinned. Zero idle footprint otherwise.

## Features

### Timer tab
- **Timed wake mode** — inhibit power management for 15m, 30m, 1h, 2h, 4h, or indefinitely (`∞`).
- **Two inhibition modes**
  - `full` — inhibit power management *and* the screen saver.
  - `sleep` — inhibit power management only (display still sleeps).
- **Optional CLI** — the same helper is scriptable from the terminal.

### Fan tab (ThinkPad only)
- Fan RPM, temperature, CPU frequency and throttling state in the popup.
- **Throttling indicator** — the frequency turns red the moment the CPU is
  thermally throttled.
- One-click fan levels: `automatic`, `0`–`7`, `full speed`.
- Honest mode reporting: automatic via thinkfan, automatic via firmware, or
  manually pinned — three different states, and the widget says which.
- Levels are *held*: the firmware and thinkfan both overwrite a manually set
  level within seconds, so a helper watches it and puts it back.
- Safety net: a pinned level is released if the CPU exceeds 90 °C.
- Failed level changes are reported in the popup instead of failing silently.

## Requirements

- KDE Plasma 6 (Plasma/Applet `6.0` API or newer)
- Qt6 (Core, DBus, Network), CMake ≥ 3.20, a C++17 compiler, `kde-cli-tools`
- For the fan tab: a ThinkPad with the `thinkpad_acpi` module
  (`/proc/acpi/ibm/fan` must exist) and fan control enabled:

  ```sh
  echo 'options thinkpad_acpi fan_control=1' | sudo tee /etc/modprobe.d/thinkpad_acpi.conf
  sudo modprobe -r thinkpad_acpi && sudo modprobe thinkpad_acpi
  ```

On non-ThinkPads the timer works normally and the Fan tab shows a notice.

## Installation

### Arch / CachyOS

```bash
sudo pacman -S --needed cmake gcc qt6-base kde-cli-tools
./install.sh
```

The script builds the timer helper (`~/.local/bin`), installs the fan helpers
(`/usr/local/bin`), the polkit rule and the hold-daemon config (`/etc`), then
registers the plasmoid with `kpackagetool6`. The fan part asks for sudo;
the rest never runs as root.

Then: panel → **Add Widgets** → **System Toolbox**.

> Restart `plasmashell` or re-login after install. Make sure `~/.local/bin` is
> on the Plasma session `PATH` (it is after a re-login).

Uninstall everything with `./install.sh --uninstall` — this restores automatic
fan control first, so the fan is never left pinned with nothing managing it.

## Usage

### Timer

Pick a duration (or `∞`), toggle **"Keep display awake too"** (`full` vs `sleep`),
press **Start**. The badge turns green and shows the remaining time. **Stop**
ends inhibition early — or let the timer expire on its own.

```bash
~/.local/bin/caffeine-timer-helper start 30 full
~/.local/bin/caffeine-timer-helper status
~/.local/bin/caffeine-timer-helper stop
```

- `start <minutes> <mode>` — begin inhibition; duration `0` = unlimited, mode is `full` or `sleep`.
- `status` — print a compact JSON status (`active`, `until`, `mode`).
- `stop` — release all inhibitors immediately.

### Fan

Click a level to pin it, **Automatic** to hand control back (to thinkfan if
installed, else to the firmware). If the fan reading stays at 0, the sensor id
differs on your model — open the widget settings and pick the right one; list
what is available with:

```sh
busctl --user call org.kde.ksystemstats1 /org/kde/ksystemstats1 \
       org.kde.ksystemstats1 allSensors | tr ' ' '\n' | grep -oE '"lmsensors/[^"]*"'
```

Tune the holder in `/etc/thinkpad-fan-hold.conf`: `INTERVAL` (seconds between
checks, default `1`) and `TCRIT` (°C, default `90`, `0` disables the safety net).

## How it works

```
┌──────────────┐   executable DataSource   ┌──────────────────────────┐
│  QML plasmoid │ ───────────────────────▶ │  caffeine-timer-helper   │
│  (contents/)  │   Unix socket (XDG_RUNTIME_DIR) ──▶ │  (native/main.cpp)       │
└──────────────┘                          └───────────┬──────────────┘
                                                      │ session D-Bus
                                                      ▼
                                    org.freedesktop.PowerManagement.Inhibit
                                    org.freedesktop.ScreenSaver

┌──────────────┐   executable DataSource   ┌──────────────────────────┐
│  Fan tab      │ ── poll ────────────────▶ │  thinkpad-fan-status     │  unprivileged
│              │ ── pkexec ──────────────▶ │  thinkpad-fan-set        │  + polkit rule
└──────────────┘                            └───────────┬──────────────┘
                                                        │ systemd transient unit
                                                        ▼
                                               thinkpad-fan-hold (root, re-asserts level)
```

- The timer helper is a single long-lived process that requests the KDE power/screen
  inhibitors over the session bus, then exits when inhibition ends.
- The fan tab polls `thinkpad-fan-status` (unprivileged) every 2 s and switches
  levels through `thinkpad-fan-set` via `pkexec` (narrow polkit rule, no password
  for the local session). Pinning spawns `thinkpad-fan-hold` as a transient
  systemd unit that re-asserts the level if the EC or thinkfan overwrites it.
- All timer communication happens over a per-user Unix socket in `XDG_RUNTIME_DIR`.

## Notes & limitations

- Uses KDE session D-Bus APIs only; **no direct `systemd-logind` inhibitor** is used.
- This does **not** guarantee protection against lid-close actions or manually
  initiated suspend.
- The throttling indicator sees **thermal** throttling only (derived from
  `package_throttle_count`); a power (RAPL/TDP) limit does not raise that counter.
- `full speed` (`disengaged`) behaves differently across models — on some it does
  not spin the fan up at all.
- Fan levels are a ThinkPad/`thinkpad_acpi` feature. On other laptops the widget
  shows sensors but the level buttons stay disabled.
- A pinned level does not survive a reboot (transient unit). To pin at boot, add
  your own unit, e.g. `/etc/systemd/system/thinkpad-fan-default.service` running
  `/usr/local/bin/thinkpad-fan-set 7`.
- The widget does not warn when `fan_control` is disabled in `thinkpad_acpi` —
  `install.sh` checks this at install time.
- KDE service API behavior may vary by Plasma release; verify build and runtime on
  your system.

## Caution

Pinning `level 0` disables the fan entirely. The 90 °C safety net helps, but do
not leave a laptop pinned at a low level under sustained load.

## Credits

Fan control ported from [plasma-thinkpad-fan](https://github.com/aiseeq/plasma-thinkpad-fan)
by AiSee (MIT). Timer core by Caffeine Timer.

## License

MIT
