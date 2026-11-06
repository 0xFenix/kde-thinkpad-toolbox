#!/usr/bin/env bash
# All-in-one installer: Caffeine Timer helper + ThinkPad fan helpers + plasmoid.
#
#   ./install.sh            build, install or upgrade everything
#   ./install.sh --uninstall remove everything this script installed
#
# The keep-awake timer works everywhere. The fan tab only activates on a
# ThinkPad with thinkpad_acpi fan control; on other machines the helpers are
# still installed (a few KB) but the tab stays hidden.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLET_ID=org.local.caffeinetimer
FAN_HELPERS=(thinkpad-fan-status thinkpad-fan-set thinkpad-fan-hold)
POLICY=com.github.aiseeq.thinkpadfan.policy
FAN=/proc/acpi/ibm/fan

die() { echo "error: $*" >&2; exit 1; }

# Run as your normal user: the applet and timer helper live in *your* ~/.local,
# and under sudo that would be /root/.local — installed for nobody.
[[ $EUID -ne 0 ]] ||
    die "do not run this with sudo — run it as your user, it will ask for sudo itself"

# System files (fan helpers, polkit rule) need root; the rest must not use it.
SUDO=""
need_root() {
    command -v sudo >/dev/null || die "sudo is required to install the system files"
    SUDO=sudo
}

if [[ "${1:-}" == "--uninstall" ]]; then
    need_root
    kpackagetool6 --type Plasma/Applet --remove "$APPLET_ID" 2>/dev/null || true
    rm -f "$HOME/.local/bin/caffeine-timer-helper"
    # Restore automatic fan control FIRST, while we still can: stopping the
    # hold daemon alone would leave the fan pinned at the last manual level
    # with nothing managing it.
    if [[ -e "$FAN" ]]; then
        $SUDO systemctl stop thinkpad-fan-hold.service 2>/dev/null || true
        $SUDO systemctl reset-failed thinkpad-fan-hold.service 2>/dev/null || true
        echo "level auto" | $SUDO tee "$FAN" >/dev/null || true
    fi
    for h in "${FAN_HELPERS[@]}"; do $SUDO rm -f "/usr/local/bin/$h"; done
    $SUDO rm -f "/usr/share/polkit-1/actions/$POLICY"
    echo "removed (kept /etc/thinkpad-fan-hold.conf if you tuned it)."
    echo 'Restart the panel: systemctl --user restart plasma-plasmashell'
    exit 0
fi

# --- 1. timer helper (user level) ---------------------------------------------
cmake -S "$HERE/native" -B "$HERE/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$HERE/build" -j "$(nproc)"
install -Dm755 "$HERE/build/caffeine-timer-helper" "$HOME/.local/bin/caffeine-timer-helper"
echo 'timer helper -> ~/.local/bin/caffeine-timer-helper'

# --- 2. fan helpers + polkit (system level) ------------------------------------
need_root

for h in "${FAN_HELPERS[@]}"; do
    $SUDO install -m 0755 "$HERE/helpers/$h" "/usr/local/bin/$h"
done
echo 'fan helpers  -> /usr/local/bin/'

$SUDO install -m 0644 "$HERE/polkit/$POLICY" "/usr/share/polkit-1/actions/$POLICY"
echo "polkit       -> /usr/share/polkit-1/actions/$POLICY"

if [[ ! -e /etc/thinkpad-fan-hold.conf ]]; then
    $SUDO install -m 0644 "$HERE/helpers/thinkpad-fan-hold.conf" /etc/thinkpad-fan-hold.conf
    echo 'hold config   -> /etc/thinkpad-fan-hold.conf'
fi

if [[ ! -e "$FAN" ]]; then
    cat >&2 <<'EOF'
warning: /proc/acpi/ibm/fan not found — no ThinkPad fan interface on this machine.
         The timer works fine; the Fan tab will stay hidden.
EOF
elif [[ "$(cat /sys/module/thinkpad_acpi/parameters/fan_control 2>/dev/null)" != "Y" ]]; then
    cat >&2 <<'EOF'
warning: fan control is disabled in thinkpad_acpi, manual fan levels will not work.
         Enable it with:

           echo 'options thinkpad_acpi fan_control=1' | sudo tee /etc/modprobe.d/thinkpad_acpi.conf
           sudo modprobe -r thinkpad_acpi && sudo modprobe thinkpad_acpi

EOF
fi

# --- 3. applet -----------------------------------------------------------------
command -v kpackagetool6 >/dev/null || die "kpackagetool6 not found — is Plasma 6 installed?"

if kpackagetool6 --type Plasma/Applet --list 2>/dev/null | grep -qx "$APPLET_ID"; then
    kpackagetool6 --type Plasma/Applet --upgrade "$HERE"
else
    kpackagetool6 --type Plasma/Applet --install "$HERE"
fi
echo "applet       -> $APPLET_ID"

cat <<'EOF'

Done. Now:
  1. systemctl --user restart plasma-plasmashell (or re-login)
  2. right-click the panel -> Add Widgets -> "Caffeine & Fan Control"
  3. if the fan reading stays 0, open the widget settings and pick the right
     sensor id (the settings page shows how to list them)
EOF
