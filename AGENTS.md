# AGENTS.md

KDE Plasma 6 "System Toolbox" plasmoid — one panel icon opening a popup with
tool tabs (currently **Timer** + **Fan**), a native C++/Qt6 D-Bus helper for the
timer, and three small bash helpers for ThinkPad fan control. **No Python.**
(Dir is `caffeine-timer-native`; GitHub remote is `kde-caffeine-timer`.)

## Components and IPC

- `contents/ui/main.qml` — the plasmoid. Panel shows a single icon
  (`applications-system`, `chronometer` while the timer runs); click opens the
  popup. Tab switcher is two plain `PC3.Button`s (`currentTab`), not a TabBar.
  Pages are `ColumnLayout`s toggled by `visible`.
- Timer path: `P5.DataSource id: executor` (`engine: "executable"`) runs
  `caffeine-timer-helper <args>` and parses **JSON**.
- Fan path: separate `P5.DataSource id: fanExec`. Status output is
  `level|thinkfan|mhz|throttle-count` (NOT JSON) — keep the two DataSources
  apart. `fanExec.setLevel()` calls `pkexec thinkpad-fan-set <level>`; the value
  only ever comes from fixed buttons. Set-failures surface via `fanError`
  (exit code + stderr); do not swallow them.
- Fan detection is runtime: `fanLevel === "n/a"` (helper ran, no
  `/proc/acpi/ibm/fan`) → Fan tab shows a notice, level buttons disabled. Never
  assume a ThinkPad.
- `native/main.cpp` — one binary, two modes: `--serve` (daemon on per-user Unix
  socket `$XDG_RUNTIME_DIR/caffeine-timer-<uid>.sock`) vs CLI client. Inhibition
  via KDE session D-Bus only (`PowerManagement.Inhibit`, `ScreenSaver`); no
  systemd-logind. Ends with `#include "main.moc"` — needs `CMAKE_AUTOMOC ON`.
- `helpers/thinkpad-fan-{status,set,hold}` — bash. `set` runs as **root** via
  pkexec; validates arg strictly (`auto|0-7|full`). `hold` runs as a transient
  systemd unit (`systemd-run --collect --unit=thinkpad-fan-hold`) and re-asserts
  the level; reads tunables from `/etc/thinkpad-fan-hold.conf` with env override.
  `hold` must validate INTERVAL/TCRIT **before** touching hardware.
- `polkit/*.policy` — action id `com.github.aiseeq.thinkpadfan.set` is kept
  stable on purpose (existing installs keep working).
- `contents/config/{config.qml,main.xml}` + `contents/ui/ConfigGeneral.qml` —
  fan sensor settings. No `i18n()` anywhere in QML (plain strings, matching the
  timer code); if you add config strings, keep them plain.

## Build / install

- `./install.sh` builds **and** installs: cmake timer helper → `~/.local/bin`,
  fan helpers → `/usr/local/bin` + polkit + `/etc/thinkpad-fan-hold.conf`
  (sudo, only if missing), then `kpackagetool6 install/upgrade .`.
- `--uninstall` restores `level auto` to the fan FIRST (never leave it pinned),
  then removes helpers, polkit rule, applet. Keeps the .conf if tuned.
- Build only: `cmake -S native -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j"$(nproc)"`.
- `build/` is gitignored. Applet id `metadata.json` → `org.local.caffeinetimer`
  (kept across the 2.0→3.0 rename; do not change it or installs orphan).
- Deps: Qt6 (Core/DBus/Network) + `Sensors`/`ksysguard` QML imports, CMake ≥ 3.20,
  C++17, `kde-cli-tools`. Helper must be on plasmashell `PATH` (`~/.local/bin`).

## Gotchas

- Modes: timer `full` = power + screen inhibit, `sleep` = power only, duration
  `0` = unlimited. Fan: `autoMode` = thinkfan OR firmware-auto; anything else is
  a pinned manual level. `hasFan`/`fanDetected` false also covers "not polled
  yet" (`fanLevel === ""`).
- `stop_hold` + `systemd-run` reuse one unit name: `stop` blocks till stopped,
  and `--collect` GCs dead units — keep both, or rapid re-pins fail.
- `hold` writes `level N` (no tabs) — thinkpad_acpi accepts it; don't "fix".
- Safety net (`TCRIT`) is force-disabled for levels 6/7/full-speed by design
  (they cool better than auto). `level 0` = fan off: treat changes here carefully.
- `qmllint contents/ui/main.qml contents/ui/ConfigGeneral.qml` passes clean —
  keep it that way. No test suite, CI, or linter otherwise.
- Commits use Conventional Commits (`feat:`, `fix:`, `docs:`, …).

## Verify a change

- Scripts: `bash -n helpers/* install.sh`.
- Timer helper: build, then `QT_QPA_PLATFORM=offscreen ./build/caffeine-timer-helper status`.
- Status: `./helpers/thinkpad-fan-status` → `level|thinkfan|mhz|count`.
- Hold logic without touching hardware: copy `hold` to /tmp with `FAN=` pointed
  at a fake file, then check foreign-level restore and `TCRIT=1` safety-net exit.
- Live pin/set needs root (`/proc/acpi/ibm/fan` + pkexec/systemd) — cannot be
  verified headless; review carefully instead.
- QML: after `./install.sh`, `kpackagetool6 --upgrade` or restart plasmashell.
