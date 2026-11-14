#!/usr/bin/env bash
# Driver and battery-life tuning for the Lenovo Yoga Slim 7 14IMH9 (83CV) on Ubuntu 26.10.
#
#   Run once, after Ubuntu is installed:   sudo bash install.sh
#   Remove everything it wrote:            sudo bash install.sh --undo
#
# Run it from a terminal inside your desktop session, so it can also set the
# desktop options (dark style, screen dimming). Safe to run again.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG=/var/log/yoga-slim7-tuning.log
STATE_DIR=/var/lib/yoga-slim7
GS_BACKUP=$STATE_DIR/gsettings.before
GS_USER_FILE=$STATE_DIR/desktop-user

AUDIO_CONF=/etc/modprobe.d/yoga-slim7-audio.conf
SYSCTL_CONF=/etc/sysctl.d/90-yoga-slim7-power.conf
UDEV_RULES=/etc/udev/rules.d/90-yoga-slim7-power.rules
NM_CONF=/etc/NetworkManager/conf.d/90-yoga-slim7-wifi-powersave.conf
GRUB_DROPIN=/etc/default/grub.d/90-yoga-slim7-power.cfg
AUTO_UNIT=/etc/systemd/system/yoga-power-auto.service
SLEEP_HOOK=/usr/lib/systemd/system-sleep/yoga-sleep-report
HELPER=/usr/local/bin/yoga-power
CONFIG=/etc/yoga-power.conf

# Everything here is in the Ubuntu 26.10 archive (checked 2026-11-15).
PACKAGES=(
    firmware-sof-signed alsa-ucm-conf alsa-utils      # sound firmware and routing
    intel-media-va-driver vainfo intel-gpu-tools      # hardware video decode
    thermald power-profiles-daemon                    # thermal and power profiles
    powertop lm-sensors nvme-cli iw fwupd             # diagnostics and firmware updates
)
LPMD_PACKAGE=intel-lpmd                               # Intel's workload-aware CPU tuning daemon

MODE=install
FORCE=0
WITH_LPMD=1
KEEP_DESKTOP=0
WARNINGS=0
DESK_USER=""
DESK_UID=""

say()  { printf '\n== %s\n' "$*"; }
ok()   { printf '   ok    %s\n' "$*"; }
skip() { printf '   skip  %s\n' "$*"; }
warn() { printf '   WARN  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo bash install.sh [--undo] [--keep-desktop] [--no-lpmd] [--force]

  --undo          remove the files this script wrote and put the desktop options back
                  (packages are left installed)
  --keep-desktop  do not change desktop options (dark style, dimming, idle times)
  --no-lpmd       do not install intel-lpmd (Intel's workload-aware CPU daemon)
  --force         run even if this is not a Yoga Slim 7 14IMH9 (83CV)
EOF
}

for arg in "$@"; do
    case "$arg" in
        --undo) MODE=undo ;;
        --keep-desktop) KEEP_DESKTOP=1 ;;
        --no-lpmd) WITH_LPMD=0 ;;
        --force) FORCE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown option: $arg" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "run this with sudo:  sudo bash install.sh"

exec > >(tee -a "$LOG") 2>&1
printf '\n##### %s  install.sh %s\n' "$(date '+%F %T')" "$*"

# ---------------------------------------------------------------------------
check_machine() {
    say "Checking the machine"
    local product version
    product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
    version=$(cat /sys/class/dmi/id/product_version 2>/dev/null || true)
    if [ "$product" = "83CV" ]; then
        ok "$version ($product), kernel $(uname -r)"
    elif [ "$FORCE" -eq 1 ]; then
        warn "this is '$version' ($product), not an 83CV; continuing because of --force"
    else
        die "this is '$version' ($product), not a Yoga Slim 7 14IMH9 (83CV). Use --force to run anyway."
    fi

    if [ -d /run/casper ] || grep -q casper /proc/cmdline || [ "$(findmnt -no FSTYPE / 2>/dev/null)" = overlay ]; then
        die "this looks like the live USB session. Install Ubuntu to the SSD first, boot it, then run this script."
    fi
}

# ---------------------------------------------------------------------------
install_packages() {
    say "Installing driver and power packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q || warn "apt-get update failed; is the laptop online?"

    local list=("${PACKAGES[@]}") pkg
    [ "$WITH_LPMD" -eq 1 ] && list+=("$LPMD_PACKAGE")

    for pkg in "${list[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            skip "$pkg (already installed)"
        elif apt-get install -y -q "$pkg" >/dev/null; then
            ok "$pkg"
        else
            warn "could not install $pkg"
        fi
    done

    if dpkg-query -W -f='${Status}' tlp 2>/dev/null | grep -q 'install ok installed'; then
        warn "TLP is installed and fights with power-profiles-daemon. Remove one of them (suggested: sudo apt remove tlp)."
    fi
}

# ---------------------------------------------------------------------------
# The kernel has no entry for this laptop's sound codec (17aa:38d8), so the two
# woofers are not routed and the speakers sound thin. This applies the same
# routing the kernel uses for the sister Yoga 9 models.
fix_speakers() {
    say "Speakers (woofer routing)"
    if ! grep -qis 'Subsystem Id: 0x17aa38d8' /proc/asound/card*/codec#*; then
        warn "sound codec 17aa:38d8 not found, speaker fix skipped (check: cat /proc/asound/card*/codec#* | grep -i subsystem)"
        return
    fi

    local want='options snd-sof-intel-hda-generic hda_model=alc287-yoga9-bass-spk-pin'
    if [ -f "$AUDIO_CONF" ] && grep -qxF "$want" "$AUDIO_CONF"; then
        skip "$AUDIO_CONF (already in place)"
        return
    fi

    cat > "$AUDIO_CONF" <<EOF
# Yoga Slim 7 14IMH9 (83CV): route the two woofers (codec 17aa:38d8 has no kernel quirk).
# Written by yoga-slim7-ubuntu/install.sh. Delete this file if a later kernel handles it natively.
$want
EOF
    ok "wrote $AUDIO_CONF"

    if command -v update-initramfs >/dev/null; then
        update-initramfs -u >/dev/null && ok "initramfs updated" || warn "update-initramfs failed"
    fi
}

# ---------------------------------------------------------------------------
tune_devices() {
    say "Device power saving"

    cat > "$SYSCTL_CONF" <<'EOF'
# Yoga Slim 7 14IMH9 (written by yoga-slim7-ubuntu/install.sh).
# The NMI watchdog wakes the CPU for nothing on a laptop.
kernel.nmi_watchdog = 0
EOF
    sysctl -q -p "$SYSCTL_CONF" && ok "wrote and applied $SYSCTL_CONF" || warn "could not apply $SYSCTL_CONF"

    cat > "$UDEV_RULES" <<'EOF'
# Yoga Slim 7 14IMH9 (written by yoga-slim7-ubuntu/install.sh).
# PCI devices: allow runtime power management. Drivers that cannot do it ignore this.
ACTION=="add", SUBSYSTEM=="pci", TEST=="power/control", ATTR{power/control}="auto"
# Built-in camera (Chicony 04f2:b7f5): suspend it when no application is using it.
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="04f2", ATTR{idProduct}=="b7f5", TEST=="power/control", ATTR{power/control}="auto"
# Charger plugged in or pulled out: switch between the mains and the battery settings.
ACTION=="change", SUBSYSTEM=="power_supply", ATTR{type}=="Mains", RUN+="/usr/bin/systemctl --no-block start yoga-power-auto.service"
EOF
    udevadm control --reload 2>/dev/null
    ok "wrote $UDEV_RULES"

    # Apply the same thing now, without waiting for the next boot.
    local f dev n=0
    for f in /sys/bus/pci/devices/*/power/control; do
        [ -w "$f" ] && echo auto > "$f" 2>/dev/null && n=$((n + 1))
    done
    for dev in /sys/bus/usb/devices/*; do
        [ "$(cat "$dev/idVendor" 2>/dev/null)" = 04f2 ] && [ "$(cat "$dev/idProduct" 2>/dev/null)" = b7f5 ] \
            && echo auto > "$dev/power/control" 2>/dev/null
    done
    ok "runtime power management enabled on $n PCI devices and the camera"

    # Wi-Fi power save (Ubuntu normally has this on already; this pins it).
    if [ -d /etc/NetworkManager/conf.d ]; then
        cat > "$NM_CONF" <<'EOF'
# Yoga Slim 7 14IMH9 (written by yoga-slim7-ubuntu/install.sh).
# 3 = Wi-Fi power save on.
[connection]
wifi.powersave = 3
EOF
        nmcli general reload conf >/dev/null 2>&1
        ok "wrote $NM_CONF (takes effect on the next Wi-Fi connection)"
    else
        skip "NetworkManager not found, Wi-Fi power save left alone"
    fi
}

# ---------------------------------------------------------------------------
enable_services() {
    say "Power services"
    local unit
    for unit in thermald.service power-profiles-daemon.service; do
        if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .; then
            systemctl enable --now "$unit" >/dev/null 2>&1 && ok "$unit enabled" || warn "could not start $unit"
        else
            warn "$unit is not installed"
        fi
    done
    if [ "$WITH_LPMD" -eq 1 ]; then
        local found=0
        for unit in intel_lpmd.service intel-lpmd.service; do
            if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .; then
                found=1
                systemctl enable --now "$unit" >/dev/null 2>&1 && ok "$unit enabled" || warn "could not start $unit"
            fi
        done
        [ "$found" -eq 1 ] || warn "intel-lpmd service not found"
    fi

    if grep -q '\[s2idle\]' /sys/power/mem_sleep 2>/dev/null; then
        ok "suspend mode is s2idle (the only mode this CPU supports)"
    else
        warn "unexpected suspend mode: $(cat /sys/power/mem_sleep 2>/dev/null)"
    fi
}

# ---------------------------------------------------------------------------
# One kernel boot option: let background kernel work run on whichever core is
# already awake instead of waking a sleeping one.
tune_boot() {
    say "Kernel boot option"
    local param=/sys/module/workqueue/parameters/power_efficient
    if [ "$(cat "$param" 2>/dev/null)" = Y ] && [ ! -f "$GRUB_DROPIN" ]; then
        skip "power-efficient workqueues are already on in this kernel"
        return
    fi
    if [ ! -f /etc/default/grub ] || ! command -v update-grub >/dev/null; then
        skip "this install does not boot through GRUB, boot option not added"
        return
    fi
    mkdir -p /etc/default/grub.d
    cat > "$GRUB_DROPIN" <<'EOF'
# Yoga Slim 7 14IMH9 (written by yoga-slim7-ubuntu/install.sh).
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT workqueue.power_efficient=1"
EOF
    if update-grub >/dev/null 2>&1; then
        ok "wrote $GRUB_DROPIN (active after the next reboot)"
    else
        rm -f "$GRUB_DROPIN"
        warn "update-grub failed, boot option removed again"
    fi
}

# ---------------------------------------------------------------------------
install_tools() {
    say "Helper tools and automatic battery/mains switching"
    install -D -m 755 "$KIT_DIR/files/yoga-power" "$HELPER" \
        && ok "installed $HELPER" || warn "could not install $HELPER"
    install -D -m 755 "$KIT_DIR/files/yoga-sleep-report" "$SLEEP_HOOK" \
        && ok "installed $SLEEP_HOOK (logs every suspend to /var/log/yoga-sleep.log)" \
        || warn "could not install $SLEEP_HOOK"
    # The USB stick is FAT, which can leave Windows line endings behind; strip them.
    sed -i 's/\r$//' "$HELPER" "$SLEEP_HOOK" 2>/dev/null

    if [ -f "$CONFIG" ]; then
        skip "$CONFIG (kept your existing settings)"
    else
        cat > "$CONFIG" <<'EOF'
# Settings for "yoga-power apply", which runs at boot, after resume, and
# whenever the charger is plugged in or pulled out.
# After editing, run:  sudo yoga-power apply

# Power profile to select on battery and on mains.
# Choices: power-saver, balanced, performance. Empty = do not switch.
ON_BATTERY_PROFILE=power-saver
ON_AC_PROFILE=balanced

# 1 = switch CPU turbo boost off on battery. Longer runtime under load, slower bursts.
BATTERY_NO_TURBO=0

# Seconds that unwritten data may wait before the SSD is woken to store it.
# Longer lets the SSD sleep more; after a hard crash that much recent work can be lost.
BATTERY_WRITEBACK_SECS=60
AC_WRITEBACK_SECS=15
EOF
        ok "wrote $CONFIG"
    fi

    cat > "$AUTO_UNIT" <<EOF
[Unit]
Description=Apply Yoga Slim 7 battery or mains power settings
After=power-profiles-daemon.service

[Service]
Type=oneshot
ExecStart=$HELPER apply

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    if systemctl enable yoga-power-auto.service >/dev/null 2>&1 && systemctl start yoga-power-auto.service; then
        ok "yoga-power-auto.service enabled and run once"
    else
        warn "could not start yoga-power-auto.service (see: journalctl -u yoga-power-auto)"
    fi
}

# ---------------------------------------------------------------------------
# Desktop options are per user, so they are set as the user who ran sudo.
as_user() {
    sudo -u "$DESK_USER" env XDG_RUNTIME_DIR="/run/user/$DESK_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$DESK_UID/bus" "$@"
}

find_desktop_user() {
    DESK_USER=${1:-${SUDO_USER:-}}
    [ -n "$DESK_USER" ] && [ "$DESK_USER" != root ] || return 1
    DESK_UID=$(id -u "$DESK_USER" 2>/dev/null) || return 1
    [ -S "/run/user/$DESK_UID/bus" ] || return 1
    command -v gsettings >/dev/null || return 1
}

# gs_set SCHEMA KEY VALUE: remembers the old value once, so --undo can put it back.
gs_set() {
    local old
    old=$(as_user gsettings get "$1" "$2" 2>/dev/null) || { skip "$2 (this desktop has no such option)"; return; }
    if [ "$old" = "$3" ]; then
        skip "$2 (already $3)"
        return
    fi
    grep -qs "^$1|$2|" "$GS_BACKUP" || printf '%s|%s|%s\n' "$1" "$2" "$old" >> "$GS_BACKUP"
    if as_user gsettings set "$1" "$2" "$3" 2>/dev/null; then
        ok "$2 = $3 (was $old)"
    else
        warn "could not set $2"
    fi
}

tune_desktop() {
    say "Desktop options (OLED screen and idle behaviour)"
    if [ "$KEEP_DESKTOP" -eq 1 ]; then
        skip "left alone (--keep-desktop)"
        return
    fi
    if ! find_desktop_user; then
        warn "no desktop session found. Run this script with sudo from a terminal inside GNOME to set the desktop options."
        return
    fi
    mkdir -p "$STATE_DIR"
    echo "$DESK_USER" > "$GS_USER_FILE"

    # An OLED pixel that shows black is switched off, so the dark style is the
    # biggest single saving on this screen.
    local iface=org.gnome.desktop.interface power=org.gnome.settings-daemon.plugins.power theme
    gs_set $iface color-scheme "'prefer-dark'"
    theme=$(as_user gsettings get $iface gtk-theme 2>/dev/null | tr -d "'")
    case "$theme" in
        Yaru*-dark) ;;
        Yaru*) gs_set $iface gtk-theme "'${theme}-dark'" ;;
    esac

    gs_set $power idle-dim true                              # dim the screen when idle
    gs_set $power ambient-enabled true                       # follow the light sensor
    gs_set org.gnome.desktop.session idle-delay "uint32 180" # screen off after 3 idle minutes
    gs_set $power sleep-inactive-battery-type "'suspend'"    # on battery: suspend when idle...
    gs_set $power sleep-inactive-battery-timeout 600         # ...for 10 minutes
}

restore_desktop() {
    [ -s "$GS_BACKUP" ] || return 0
    if ! find_desktop_user "$(cat "$GS_USER_FILE" 2>/dev/null)"; then
        warn "desktop options not restored: run --undo with sudo from a terminal inside GNOME (old values are in $GS_BACKUP)"
        return 1
    fi
    local schema key value
    while IFS='|' read -r schema key value; do
        [ -n "$schema" ] || continue
        if as_user gsettings set "$schema" "$key" "$value" 2>/dev/null; then
            ok "restored $key = $value"
        else
            warn "could not restore $key"
        fi
    done < "$GS_BACKUP"
    rm -f "$GS_BACKUP" "$GS_USER_FILE"
}

# ---------------------------------------------------------------------------
undo() {
    say "Removing the tuning"
    systemctl disable --now yoga-power-auto.service >/dev/null 2>&1
    local f had_grub=0
    [ -f "$GRUB_DROPIN" ] && had_grub=1
    for f in "$AUDIO_CONF" "$SYSCTL_CONF" "$UDEV_RULES" "$NM_CONF" "$GRUB_DROPIN" "$AUTO_UNIT" "$SLEEP_HOOK" "$HELPER" "$CONFIG"; do
        if [ -e "$f" ]; then rm -f "$f" && ok "removed $f"; else skip "$f (not present)"; fi
    done
    systemctl daemon-reload
    udevadm control --reload 2>/dev/null
    nmcli general reload conf >/dev/null 2>&1
    [ "$had_grub" -eq 1 ] && command -v update-grub >/dev/null && update-grub >/dev/null 2>&1
    command -v update-initramfs >/dev/null && update-initramfs -u >/dev/null
    restore_desktop
    echo
    echo "Done. Packages were left installed. Reboot to return to Ubuntu's defaults."
}

# ---------------------------------------------------------------------------
if [ "$MODE" = undo ]; then
    undo
    exit 0
fi

check_machine
install_packages
fix_speakers
tune_devices
enable_services
tune_boot
install_tools
tune_desktop

say "Current state"
"$HELPER" status || true

echo
if [ "$WARNINGS" -gt 0 ]; then
    echo "Finished with $WARNINGS warning(s); see the WARN lines above. Log: $LOG"
else
    echo "Finished with no warnings. Log: $LOG"
fi
echo "Reboot now so the speaker fix and the boot option take effect."
echo "Then unplug the charger and run:  yoga-power measure"
