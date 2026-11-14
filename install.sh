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

# Hibernation
HIB_GRUB=/etc/default/grub.d/91-yoga-slim7-hibernate.cfg
HIB_INITRAMFS=/etc/initramfs-tools/conf.d/yoga-slim7-resume
HIB_DRACUT=/etc/dracut.conf.d/90-yoga-slim7-resume.conf
FSTAB_BACKUP=/etc/fstab.yoga-slim7.bak
LID_CONF=/etc/systemd/logind.conf.d/90-yoga-slim7-lid.conf     # written by "yoga-power lid"
SLEEP_CONF=/etc/systemd/sleep.conf.d/90-yoga-slim7.conf        # written by "yoga-power lid"
HIB_SWAP=""
HIB_SWAP_TYPE=""

# Speaker sound tuning (Dolby profile rebuilt as a PipeWire filter)
OPT_DIR=/opt/yoga-slim7
TUNING_XML_NAME=DEV_0287_SUBSYS_17AA38D8_PCI_SUBSYS_383917AA.xml
SPEAKER_TOOL_DIR=$OPT_DIR/speaker-tuning-to-easyeffects
SPEAKER_TOOL_REPO=https://github.com/antoinecellerier/speaker-tuning-to-easyeffects.git
SPEAKER_TOOL_TAG=v2026.10.1
SPEAKER_TOOL_COMMIT=2838efda3e5bcac4002ec91c78a43a66f8ada878      # what that tag pointed at on 2026-11-15
SPEAKER_PACKAGES=(git python3-numpy python3-scipy python3-rich lsp-plugins-lv2 calf-plugins lilv-utils)

# Face login (Howdy 3, from its author's PPA; it is not in the Ubuntu archive)
HOWDY_PPA=ppa:boltgolt/howdy
HOWDY_CONFIG=/etc/howdy/config.ini
HOWDY_MARKER=$STATE_DIR/howdy-installed-by-kit

# Claude Desktop and the Claude Code CLI, from Anthropic's signed apt repositories.
# Both repositories are signed with the same key; its fingerprint is published at
# https://code.claude.com/docs/en/setup and checked before the key is trusted.
CLAUDE_KEY_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
CLAUDE_DESKTOP_KEY_URL=https://downloads.claude.ai/claude-desktop/key.asc
CLAUDE_DESKTOP_KEY=/usr/share/keyrings/claude-desktop-archive-keyring.asc
CLAUDE_DESKTOP_LIST=/etc/apt/sources.list.d/claude-desktop.list
CLAUDE_CODE_KEY_URL=https://downloads.claude.ai/keys/claude-code.asc
CLAUDE_CODE_KEY=/etc/apt/keyrings/claude-code.asc
CLAUDE_CODE_LIST=/etc/apt/sources.list.d/claude-code.list
CLAUDE_MARKER=$STATE_DIR/claude-installed-by-kit

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
WITH_HIBERNATE=1
WITH_SPEAKER_TUNING=1
WITH_FACE_LOGIN=1
WITH_CLAUDE=1
CLAUDE_READY=0
KEEP_DESKTOP=0
WARNINGS=0
DESK_USER=""
DESK_UID=""
DESK_HOME=""
FACE_LOGIN_READY=0

say()  { printf '\n== %s\n' "$*"; }
ok()   { printf '   ok    %s\n' "$*"; }
skip() { printf '   skip  %s\n' "$*"; }
warn() { printf '   WARN  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo bash install.sh [--undo] [--keep-desktop] [--no-hibernate] [--no-speaker-tuning]
                            [--no-face-login] [--no-claude] [--no-lpmd] [--force]

  --undo               remove what this script set up and put the desktop options back
                       (ordinary packages and the enlarged swapfile are left in place)
  --keep-desktop       do not change desktop options (dark style, dimming, idle times)
  --no-hibernate       do not set up hibernation (no swapfile change, no resume boot option)
  --no-speaker-tuning  fix the woofers only; do not add the Dolby sound profile
  --no-face-login      do not install Howdy face login
  --no-claude          do not install Claude Desktop and the Claude Code CLI
  --no-lpmd           do not install intel-lpmd (Intel's workload-aware CPU daemon)
  --force              run even if this is not a Yoga Slim 7 14IMH9 (83CV)
EOF
}

for arg in "$@"; do
    case "$arg" in
        --undo) MODE=undo ;;
        --keep-desktop) KEEP_DESKTOP=1 ;;
        --no-hibernate) WITH_HIBERNATE=0 ;;
        --no-speaker-tuning) WITH_SPEAKER_TUNING=0 ;;
        --no-face-login) WITH_FACE_LOGIN=0 ;;
        --no-claude) WITH_CLAUDE=0 ;;
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
# Hibernation writes the whole memory to swap and powers off, so it needs a
# swap area at least as large as the RAM and a boot option that tells the
# kernel where to find the saved image.

# Finds a swap area big enough for a hibernation image. If there is none, the
# swapfile is replaced by a larger one (or /swap.img is created).
# Sets HIB_SWAP and HIB_SWAP_TYPE; returns non-zero after a WARN on failure.
ensure_hibernate_swap() {
    local mem_bytes=$1 need_gib=$2 name type size file=""
    while read -r name type size; do
        [ -n "$name" ] || continue
        if [ "$size" -ge "$mem_bytes" ]; then
            HIB_SWAP=$name
            HIB_SWAP_TYPE=$type
            skip "$name is already large enough ($((size / 1073741824)) GiB)"
            return 0
        fi
        [ "$type" = file ] && [ -z "$file" ] && file=$name
    done < <(swapon --show=NAME,TYPE,SIZE --bytes --noheadings 2>/dev/null)

    [ -n "$file" ] || file=/swap.img
    local dir new="$file.new" avail_kib fstype
    dir=$(dirname "$file")
    fstype=$(findmnt -no FSTYPE -T "$dir" 2>/dev/null)
    if [ "$fstype" != ext4 ]; then
        warn "$dir is on $fstype; this script only builds a hibernation swapfile on ext4"
        return 1
    fi
    # The new file is written next to the old one first, and 10 GiB must stay free afterwards.
    avail_kib=$(df --output=avail -k "$dir" | tail -n 1 | tr -d ' ')
    if [ "$avail_kib" -lt $(( (need_gib + 10) * 1048576 )) ]; then
        warn "not enough free disk space for a ${need_gib} GiB swapfile (free: $((avail_kib / 1048576)) GiB)"
        return 1
    fi

    rm -f "$new"
    if ! fallocate -l "${need_gib}G" "$new" || ! chmod 600 "$new" || ! mkswap -q "$new" >/dev/null; then
        rm -f "$new"
        warn "could not create ${need_gib} GiB swapfile $new; the existing swap was left untouched"
        return 1
    fi
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "$file"; then
        if ! swapoff "$file"; then
            rm -f "$new"
            warn "could not switch off $file (memory too full?). Close some applications and run this script again."
            return 1
        fi
    fi
    mv -f "$new" "$file"
    if ! swapon -p 100 "$file"; then
        warn "could not switch on the new swapfile $file"
        return 1
    fi

    # Make it permanent, with the highest priority so hibernation always picks it.
    [ -f "$FSTAB_BACKUP" ] || cp -a /etc/fstab "$FSTAB_BACKUP"
    awk -v f="$file" '$1 != f' /etc/fstab > /etc/fstab.yoga-tmp \
        && printf '%s none swap sw,pri=100 0 0\n' "$file" >> /etc/fstab.yoga-tmp \
        && cat /etc/fstab.yoga-tmp > /etc/fstab
    rm -f /etc/fstab.yoga-tmp

    HIB_SWAP=$file
    HIB_SWAP_TYPE=file
    ok "swapfile $file is now ${need_gib} GiB (old /etc/fstab saved as $FSTAB_BACKUP)"
}

setup_hibernate() {
    say "Hibernation"
    if [ "$WITH_HIBERNATE" -eq 0 ]; then
        skip "left alone (--no-hibernate)"
        return
    fi
    if ! grep -qw disk /sys/power/state 2>/dev/null; then
        warn "this kernel does not offer hibernation"
        return
    fi
    if [ -r /sys/kernel/security/lockdown ] && ! grep -q '\[none\]' /sys/kernel/security/lockdown; then
        warn "Secure Boot is on, and Ubuntu refuses to hibernate while it is. Switch Secure Boot off in the BIOS setup (press F2 at power-on, then Security > Secure Boot), boot Ubuntu and run this script again."
        return
    fi
    if [ ! -f /etc/default/grub ] || ! command -v update-grub >/dev/null; then
        warn "this install does not boot through GRUB; hibernation was not set up"
        return
    fi

    local mem_kib mem_bytes need_gib uuid offset params
    mem_kib=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    mem_bytes=$((mem_kib * 1024))
    need_gib=$(( (mem_kib + 1048575) / 1048576 + 1 ))      # RAM rounded up, plus 1 GiB of headroom

    ensure_hibernate_swap "$mem_bytes" "$need_gib" || return

    if [ "$HIB_SWAP_TYPE" = file ]; then
        uuid=$(findmnt -no UUID -T "$HIB_SWAP" 2>/dev/null)
        # Where the file starts on the disk, counted in filesystem blocks.
        offset=$(filefrag -v "$HIB_SWAP" 2>/dev/null | awk '$1 == "0:" { gsub(/\./, "", $4); print $4; exit }')
        case "$offset" in
            ''|*[!0-9]*) warn "could not read where $HIB_SWAP starts on the disk; hibernation was not set up"; return ;;
        esac
        params="resume=UUID=$uuid resume_offset=$offset"
    else
        uuid=$(blkid -s UUID -o value "$HIB_SWAP" 2>/dev/null)
        params="resume=UUID=$uuid"
    fi
    if [ -z "$uuid" ]; then
        warn "could not read the disk identifier for $HIB_SWAP; hibernation was not set up"
        return
    fi

    mkdir -p /etc/default/grub.d
    cat > "$HIB_GRUB" <<EOF
# Yoga Slim 7 14IMH9 (written by yoga-slim7-ubuntu/install.sh).
# Tells the kernel where the hibernation image is ($HIB_SWAP).
# Run install.sh again if the swapfile is ever recreated: its position changes.
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT $params"
EOF
    if [ -d /etc/initramfs-tools/conf.d ]; then
        echo "RESUME=UUID=$uuid" > "$HIB_INITRAMFS"
    fi
    if [ -d /usr/lib/dracut/modules.d ] && command -v dracut >/dev/null; then
        mkdir -p /etc/dracut.conf.d
        echo 'add_dracutmodules+=" resume "' > "$HIB_DRACUT"
    fi

    if ! update-grub >/dev/null 2>&1; then
        rm -f "$HIB_GRUB"
        warn "update-grub failed; hibernation was not set up"
        return
    fi
    if command -v update-initramfs >/dev/null; then
        update-initramfs -u -k all >/dev/null 2>&1 || warn "update-initramfs failed; resume from hibernation may not work"
    fi
    ok "boot option added: $params"
    ok "hibernation is set up. It is NOT tied to the lid yet: reboot, then run  sudo yoga-power hibernate-test"
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
    sudo -u "$DESK_USER" env HOME="$DESK_HOME" XDG_RUNTIME_DIR="/run/user/$DESK_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$DESK_UID/bus" "$@"
}

find_desktop_user() {
    DESK_USER=${1:-${SUDO_USER:-}}
    [ -n "$DESK_USER" ] && [ "$DESK_USER" != root ] || return 1
    DESK_UID=$(id -u "$DESK_USER" 2>/dev/null) || return 1
    DESK_HOME=$(getent passwd "$DESK_USER" | cut -d: -f6)
    [ -d "$DESK_HOME" ] || return 1
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

# ---------------------------------------------------------------------------
# Speaker sound. The woofer fix makes all four speakers play; this adds the
# sound profile Windows applies on top (Dolby's tuning for this exact laptop),
# rebuilt as a PipeWire filter that loads every time sound starts.
apt_install_each() {
    local pkg failed=0
    for pkg in "$@"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            continue
        fi
        if apt-get install -y -q "$pkg" >/dev/null; then ok "$pkg"; else warn "could not install $pkg"; failed=1; fi
    done
    return "$failed"
}

# True when the converter on disk is exactly the pinned commit with no changed files.
speaker_tool_verified() {
    [ "$(git -C "$SPEAKER_TOOL_DIR" rev-parse HEAD 2>/dev/null)" = "$SPEAKER_TOOL_COMMIT" ] \
        && [ -z "$(git -C "$SPEAKER_TOOL_DIR" status --porcelain 2>/dev/null)" ]
}

speaker_filter_present() {
    ls "$DESK_HOME"/.config/pipewire/pipewire.conf.d/*[Dd]olby* >/dev/null 2>&1
}

tune_speaker_sound() {
    say "Speaker sound profile"
    if [ "$WITH_SPEAKER_TUNING" -eq 0 ]; then
        skip "left alone (--no-speaker-tuning)"
        return
    fi
    local xml_src="$KIT_DIR/dolby-tuning/$TUNING_XML_NAME" xml="$OPT_DIR/dolby-tuning/$TUNING_XML_NAME"
    if [ ! -f "$xml_src" ] && [ ! -f "$xml" ]; then
        warn "tuning file dolby-tuning/$TUNING_XML_NAME is missing from the kit"
        return
    fi
    if ! find_desktop_user; then
        warn "no desktop session found. Run this script with sudo from a terminal inside GNOME to add the sound profile."
        return
    fi
    if speaker_filter_present; then
        skip "sound profile is already installed for $DESK_USER"
        return
    fi

    apt_install_each "${SPEAKER_PACKAGES[@]}" || { warn "sound profile skipped because a package is missing"; return; }

    # Keep the tuning file and the converter on the SSD, so the USB stick is not needed later.
    mkdir -p "$OPT_DIR/dolby-tuning"
    [ -f "$xml" ] || install -m 644 "$xml_src" "$xml"
    if [ ! -f "$SPEAKER_TOOL_DIR/dolby_to_pipewire.py" ]; then
        rm -rf "$SPEAKER_TOOL_DIR"
        if ! git clone -q --depth 1 --branch "$SPEAKER_TOOL_TAG" "$SPEAKER_TOOL_REPO" "$SPEAKER_TOOL_DIR"; then
            warn "could not download the converter ($SPEAKER_TOOL_REPO)"
            return
        fi
    fi
    # A release tag can be moved to different code later; the commit hash cannot.
    # Nothing from the download is run unless it is exactly the reviewed commit.
    if ! speaker_tool_verified; then
        rm -rf "$SPEAKER_TOOL_DIR"
        warn "the downloaded converter is not the expected commit ($SPEAKER_TOOL_COMMIT); it was deleted and not run"
        return
    fi
    ok "converter $SPEAKER_TOOL_TAG verified (commit ${SPEAKER_TOOL_COMMIT:0:12}) in $SPEAKER_TOOL_DIR"

    # The converter refuses to run as root, so it runs as you. It restarts
    # PipeWire, which cuts the sound for a moment.
    if as_user sh -c 'cd "$HOME" && python3 "$1" "$2"' sh "$SPEAKER_TOOL_DIR/dolby_to_pipewire.py" "$xml" </dev/null; then
        ok "sound profile installed for $DESK_USER (pick the 'Dolby' output in the sound menu if it is not selected)"
    else
        warn "the converter reported a problem; see its messages above. Check later with: python3 $SPEAKER_TOOL_DIR/dolby_to_pipewire.py --doctor"
    fi
}

remove_speaker_sound() {
    [ -f "$SPEAKER_TOOL_DIR/dolby_to_pipewire.py" ] || return 0
    if ! speaker_tool_verified; then
        warn "the converter in $SPEAKER_TOOL_DIR is not the expected commit, so it was not run. Remove the sound profile by deleting the Dolby files in ~/.config/pipewire/pipewire.conf.d/"
        return 1
    fi
    if find_desktop_user "$(cat "$GS_USER_FILE" 2>/dev/null)"; then
        as_user sh -c 'cd "$HOME" && python3 "$1" --uninstall --yes' sh "$SPEAKER_TOOL_DIR/dolby_to_pipewire.py" </dev/null \
            && ok "sound profile removed" || warn "could not remove the sound profile"
    else
        warn "sound profile not removed: run --undo with sudo from a terminal inside GNOME"
        return 1
    fi
    rm -rf "$OPT_DIR"
}

# ---------------------------------------------------------------------------
# Face login with the infrared camera, using Howdy. Howdy tries your face
# first; if it does not recognise you, the normal password prompt follows.
find_ir_camera() {
    local dev link
    for dev in /dev/video*; do
        [ -e "$dev" ] || continue
        # The infrared sensor is the camera node that only offers greyscale.
        if v4l2-ctl -d "$dev" --list-formats 2>/dev/null | grep -q "'GREY'"; then
            # Prefer the by-path name: /dev/videoN numbers can change between boots.
            for link in /dev/v4l/by-path/*; do
                [ "$(readlink -f "$link" 2>/dev/null)" = "$dev" ] && { echo "$link"; return 0; }
            done
            echo "$dev"
            return 0
        fi
    done
    return 1
}

setup_face_login() {
    say "Face login (Howdy)"
    if [ "$WITH_FACE_LOGIN" -eq 0 ]; then
        skip "left alone (--no-face-login)"
        return
    fi

    if dpkg-query -W -f='${Status}' howdy 2>/dev/null | grep -q 'install ok installed'; then
        skip "howdy (already installed)"
    else
        apt_install_each software-properties-common v4l-utils || return
        if ! add-apt-repository -y "$HOWDY_PPA" >/dev/null 2>&1; then
            warn "could not add $HOWDY_PPA"
            return
        fi
        apt-get update -q >/dev/null 2>&1
        echo "   ...   installing Howdy. It compiles its face-recognition library; this takes several minutes."
        if apt-get install -y -q howdy howdy-gtk >/dev/null; then
            mkdir -p "$STATE_DIR"
            touch "$HOWDY_MARKER"
            ok "howdy installed from $HOWDY_PPA"
        else
            warn "Howdy did not install; see /var/log/apt/term.log"
            return
        fi
    fi

    if grep -qs pam_howdy /etc/pam.d/common-auth; then
        ok "login, lock screen and sudo try your face first, then ask for the password"
    else
        warn "Howdy is installed but not active in the login settings; run: sudo pam-auth-update"
    fi

    local cam
    if [ ! -f "$HOWDY_CONFIG" ]; then
        warn "$HOWDY_CONFIG not found; set the camera with: sudo howdy config"
    elif cam=$(find_ir_camera); then
        sed -i "s|^device_path *=.*|device_path = $cam|" "$HOWDY_CONFIG"
        if grep -qF "device_path = $cam" "$HOWDY_CONFIG"; then
            ok "infrared camera set: $cam"
        else
            warn "could not write the camera into $HOWDY_CONFIG; set device_path yourself with: sudo howdy config"
        fi
    else
        warn "no infrared camera found; set device_path yourself with: sudo howdy config"
    fi
    FACE_LOGIN_READY=1
}

remove_face_login() {
    [ -f "$HOWDY_MARKER" ] || return 0
    apt-get remove -y -q howdy howdy-gtk >/dev/null 2>&1 && ok "howdy removed" || warn "could not remove howdy"
    add-apt-repository -y --remove "$HOWDY_PPA" >/dev/null 2>&1
    rm -f "$HOWDY_MARKER"
}

# ---------------------------------------------------------------------------
# Claude Desktop (the app) and Claude Code (the "claude" terminal command),
# installed from Anthropic's own apt repositories so that both update with the
# normal system updates.

# fetch_verified_key URL DEST: downloads a signing key and installs it only if
# its fingerprint is exactly Anthropic's published one. Returns 1 when the
# download fails and 2 when the fingerprint is wrong.
fetch_verified_key() {
    local tmp gpghome fprs
    tmp=$(mktemp)
    gpghome=$(mktemp -d)
    if ! curl -fsSLo "$tmp" "$1"; then
        rm -rf "$tmp" "$gpghome"
        return 1
    fi
    # The primary-key fingerprints in the file; there must be exactly one.
    fprs=$(GNUPGHOME="$gpghome" gpg --show-keys --with-colons "$tmp" 2>/dev/null \
        | awk -F: '$1 == "pub" { primary = 1 } $1 == "fpr" && primary { print $10; primary = 0 }')
    rm -rf "$gpghome"
    if [ "$fprs" != "$CLAUDE_KEY_FPR" ]; then
        rm -f "$tmp"
        return 2
    fi
    install -D -m 644 "$tmp" "$2"
    rm -f "$tmp"
}

# add_claude_repo NAME KEY_URL KEY_FILE LIST_FILE DEB_LINE
add_claude_repo() {
    local rc
    fetch_verified_key "$2" "$3"
    rc=$?
    if [ "$rc" -eq 1 ]; then
        warn "$1: could not download the signing key ($2)"
        return 1
    elif [ "$rc" -ne 0 ]; then
        warn "$1: the downloaded signing key is not Anthropic's ($CLAUDE_KEY_FPR); nothing was installed"
        return 1
    fi
    echo "$5" > "$4"
    ok "$1: signing key verified, repository added"
}

setup_claude() {
    say "Claude Desktop and Claude Code"
    if [ "$WITH_CLAUDE" -eq 0 ]; then
        skip "left alone (--no-claude)"
        return
    fi
    apt_install_each curl gnupg || return
    mkdir -p "$STATE_DIR" /etc/apt/keyrings

    local have_desktop=0 have_code=0
    add_claude_repo "Claude Desktop" "$CLAUDE_DESKTOP_KEY_URL" "$CLAUDE_DESKTOP_KEY" "$CLAUDE_DESKTOP_LIST" \
        "deb [arch=amd64,arm64 signed-by=$CLAUDE_DESKTOP_KEY] https://downloads.claude.ai/claude-desktop/apt/stable stable main" \
        && have_desktop=1
    # "stable" is about a week behind the newest release and skips releases with regressions.
    add_claude_repo "Claude Code" "$CLAUDE_CODE_KEY_URL" "$CLAUDE_CODE_KEY" "$CLAUDE_CODE_LIST" \
        "deb [signed-by=$CLAUDE_CODE_KEY] https://downloads.claude.ai/claude-code/apt/stable stable main" \
        && have_code=1
    [ "$have_desktop" -eq 1 ] || [ "$have_code" -eq 1 ] || return
    touch "$CLAUDE_MARKER"
    apt-get update -q >/dev/null 2>&1 || warn "apt-get update reported a problem"

    if [ "$have_desktop" -eq 1 ]; then
        # With its recommended packages, which Cowork needs (QEMU and UEFI firmware).
        if apt-get install -y -q claude-desktop >/dev/null; then
            ok "claude-desktop installed (open 'Claude' from the application menu)"
            CLAUDE_READY=1
        else
            warn "claude-desktop did not install. It is a beta that Anthropic tests on Ubuntu LTS releases; see /var/log/apt/term.log"
        fi
    fi
    if [ "$have_code" -eq 1 ]; then
        if apt-get install -y -q claude-code >/dev/null; then
            ok "claude-code installed ($(claude --version 2>/dev/null || echo 'run: claude --version'))"
            CLAUDE_READY=1
        else
            warn "claude-code did not install; see /var/log/apt/term.log"
        fi
    fi

    # Cowork runs its tasks in a virtual machine and needs the kvm group for that.
    local user=${SUDO_USER:-}
    if [ -n "$user" ] && [ "$user" != root ] && getent group kvm >/dev/null; then
        if id -nG "$user" | tr ' ' '\n' | grep -qx kvm; then
            skip "$user is already in the kvm group"
        elif usermod -aG kvm "$user"; then
            ok "$user added to the kvm group for Cowork (takes effect after you log out and in)"
        else
            warn "could not add $user to the kvm group; Cowork may report a permission problem"
        fi
    fi
}

remove_claude() {
    [ -f "$CLAUDE_MARKER" ] || return 0
    apt-get remove -y -q claude-desktop claude-code >/dev/null 2>&1 && ok "claude-desktop and claude-code removed" \
        || warn "could not remove claude-desktop / claude-code"
    rm -f "$CLAUDE_DESKTOP_LIST" "$CLAUDE_CODE_LIST" "$CLAUDE_CODE_KEY" "$CLAUDE_MARKER"
    echo "   note  your Claude settings and history in ~/.claude were kept"
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
    { [ -f "$GRUB_DROPIN" ] || [ -f "$HIB_GRUB" ]; } && had_grub=1
    for f in "$AUDIO_CONF" "$SYSCTL_CONF" "$UDEV_RULES" "$NM_CONF" "$GRUB_DROPIN" "$AUTO_UNIT" "$SLEEP_HOOK" "$HELPER" "$CONFIG" \
             "$HIB_GRUB" "$HIB_INITRAMFS" "$HIB_DRACUT" "$LID_CONF" "$SLEEP_CONF"; do
        if [ -e "$f" ]; then rm -f "$f" && ok "removed $f"; else skip "$f (not present)"; fi
    done
    systemctl daemon-reload
    systemctl kill -s HUP systemd-logind 2>/dev/null
    udevadm control --reload 2>/dev/null
    nmcli general reload conf >/dev/null 2>&1
    [ "$had_grub" -eq 1 ] && command -v update-grub >/dev/null && update-grub >/dev/null 2>&1
    command -v update-initramfs >/dev/null && update-initramfs -u -k all >/dev/null 2>&1
    remove_claude
    remove_face_login
    remove_speaker_sound
    restore_desktop
    echo
    echo "Done. Packages were left installed, and the swapfile was left at its current size."
    echo "Closing the lid suspends again. Reboot to return to Ubuntu's defaults."
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
setup_hibernate
tune_desktop
tune_speaker_sound
setup_face_login
setup_claude

say "Current state"
"$HELPER" status || true

echo
if [ "$WARNINGS" -gt 0 ]; then
    echo "Finished with $WARNINGS warning(s); see the WARN lines above. Log: $LOG"
else
    echo "Finished with no warnings. Log: $LOG"
fi
echo "Reboot now so the speaker fix and the boot options take effect. After the reboot:"
echo "  1. sudo yoga-power hibernate-test   (check that hibernation really resumes)"
echo "  2. sudo yoga-power lid hibernate    (only after step 1 worked: hibernate when the lid closes)"
echo "  3. yoga-power measure               (on battery: the real power draw)"
if [ "$FACE_LOGIN_READY" -eq 1 ]; then
    echo "  4. sudo howdy add                   (look at the camera: saves your face)"
    echo "  5. sudo howdy test                  (shows what the infrared camera sees; see README if it is black)"
fi
if [ "$CLAUDE_READY" -eq 1 ]; then
    echo "  -  open Claude from the application menu and sign in; in a terminal, run: claude"
fi
