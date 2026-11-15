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
SCALE_HELPER=/usr/local/bin/yoga-scale
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
SWAP_PERCENT=150       # size of the swapfile, as a percentage of the RAM

# Speaker sound tuning (Dolby profile rebuilt as a PipeWire filter)
OPT_DIR=/opt/yoga-slim7
TUNING_XML_NAME=DEV_0287_SUBSYS_17AA38D8_PCI_SUBSYS_383917AA.xml
SPEAKER_TOOL_DIR=$OPT_DIR/speaker-tuning-to-easyeffects
SPEAKER_TOOL_REPO=https://github.com/antoinecellerier/speaker-tuning-to-easyeffects.git
SPEAKER_TOOL_TAG=v2026.10.1
SPEAKER_TOOL_COMMIT=2838efda3e5bcac4002ec91c78a43a66f8ada878      # what that tag pointed at on 2026-11-15
# libspa-0.2-modules-extra is what lets PipeWire load LV2 plugins; without it the filter cannot start.
SPEAKER_PACKAGES=(git python3-numpy python3-scipy python3-rich lsp-plugins-lv2 calf-plugins lilv-utils libspa-0.2-modules-extra)

# Face login (Howdy 3, from its author's PPA; it is not in the Ubuntu archive)
HOWDY_PPA=ppa:boltgolt/howdy
HOWDY_CONFIG=/etc/howdy/config.ini
HOWDY_MARKER=$STATE_DIR/howdy-installed-by-kit

# Infrared light for face login. This camera only flashes its infrared light for a
# moment when it starts, so Howdy scans in the dark. linux-enable-ir-emitter keeps it
# on: it sets one vendor control before each scan. The value below was found with
# `linux-enable-ir-emitter configure` on this laptop (2026-11-15) and works for it.
IR_TOOL_VERSION=7.0.0
IR_TOOL_URL=https://github.com/EmixamPP/linux-enable-ir-emitter/releases/download/$IR_TOOL_VERSION/linux-enable-ir-emitter-$IR_TOOL_VERSION-release-x86-64.tar.gz
IR_TOOL_SHA256=b5ea03b8a058b4d028d7c54dbd307b4bac2159a32cd2999da06cadc692907375   # that tarball, checked 2026-11-15
IR_TOOL=/usr/local/bin/linux-enable-ir-emitter
IR_CAMERA_ID=04f2:b7f5                     # Chicony "Integrated Camera" in the Yoga Slim 7 14IMH9
IR_CONTROL_UNIT=14
IR_CONTROL_SELECTOR=6
IR_CONTROL_VALUE="[1, 3, 2, 0, 0, 0, 0, 0, 0]"
IR_TOOL_MARKER=$STATE_DIR/ir-emitter-installed-by-kit
IR_CONFIG_MARKER=$STATE_DIR/ir-emitter-config-written-by-kit   # holds the path of the config the kit wrote

# Face ID-style popup: replaces howdy-gtk's "Loading..." window (diverted, so a Howdy
# update does not overwrite it), plus a rubberstamp that tells it about a success.
POPUP_FILE=/usr/lib/howdy-gtk/authsticky.py
POPUP_DIVERTED=/usr/lib/howdy-gtk/authsticky.py.howdy
STAMP_FILE=/lib/security/howdy/rubberstamps/faceid.py
STAMP_STATE=$STATE_DIR/howdy-rubberstamps.before          # the [rubberstamps] settings before the kit

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
WITH_ZSWAP=1
WITH_SPEAKER_TUNING=1
WITH_FACE_LOGIN=1
WITH_CLAUDE=1
CLAUDE_READY=0
KEEP_KEYRING=0
KEYRING_NAME=Default_keyring
KEYRING_BACKUP=$STATE_DIR/keyring-default.before
KEEP_DESKTOP=0
WITH_FONTS=0
FONTS_READY=0
FONT_CONF_NAME=45-yoga-slim7-fonts.conf
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
Usage: sudo bash install.sh [--undo] [--keep-desktop] [--windows-fonts] [--no-hibernate] [--no-zswap]
                            [--no-speaker-tuning] [--no-face-login] [--no-claude]
                            [--keep-keyring] [--no-lpmd] [--force]

  --undo               remove what this script set up and put the desktop options back
                       (ordinary packages and the enlarged swapfile are left in place)
  --keep-desktop       do not change desktop options (dark style, dimming, idle times)
  --windows-fonts      also switch to Windows-like fonts (Selawik, Consolas) and greyscale
                       text smoothing; without it, Ubuntu's fonts are left alone
  --no-hibernate       do not set up hibernation (no swapfile change, no resume boot option)
  --no-zswap           do not switch on compressed swap (zswap)
  --no-speaker-tuning  fix the woofers only; do not add the Dolby sound profile
  --no-face-login      do not install Howdy face login
  --no-claude          do not install Claude Desktop and the Claude Code CLI
  --keep-keyring       leave the password keyring alone (it stays locked by your login
                       password, and asks for it after a face login)
  --no-lpmd            do not install intel-lpmd (Intel's workload-aware CPU daemon)
  --force              run even if this is not a Yoga Slim 7 14IMH9 (83CV)
EOF
}

for arg in "$@"; do
    case "$arg" in
        --undo) MODE=undo ;;
        --keep-desktop) KEEP_DESKTOP=1 ;;
        --windows-fonts) WITH_FONTS=1 ;;
        --no-hibernate) WITH_HIBERNATE=0 ;;
        --no-zswap) WITH_ZSWAP=0 ;;
        --no-speaker-tuning) WITH_SPEAKER_TUNING=0 ;;
        --no-face-login) WITH_FACE_LOGIN=0 ;;
        --no-claude) WITH_CLAUDE=0 ;;
        --keep-keyring) KEEP_KEYRING=1 ;;
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
# Kernel boot options. Each is added only when the kernel does not already do
# it by itself.
#  - workqueue.power_efficient: background kernel work runs on whichever core
#    is already awake instead of waking a sleeping one.
#  - zswap: memory pages on their way to the swapfile are compressed and kept
#    in RAM first, so a laptop that swaps (16 GB fills up quickly with several
#    browser-based applications) wakes and writes the SSD far less often.

# needs_boot_param FILE NAME: true when the feature is off, or is on only
# because an earlier run of this script put NAME on the kernel command line.
needs_boot_param() {
    [ -r "$1" ] || return 1                       # this kernel has no such feature
    [ "$(cat "$1")" != Y ] || grep -qw "$2" /proc/cmdline
}

tune_boot() {
    say "Kernel boot options"
    local params=""
    if needs_boot_param /sys/module/workqueue/parameters/power_efficient workqueue.power_efficient=1; then
        params="workqueue.power_efficient=1"
    else
        skip "power-efficient work queues are already on in this kernel"
    fi
    if [ "$WITH_ZSWAP" -eq 0 ]; then
        skip "compressed swap left alone (--no-zswap)"
    elif needs_boot_param /sys/module/zswap/parameters/enabled zswap.enabled=1; then
        params="$params zswap.enabled=1 zswap.compressor=lz4"
    else
        skip "compressed swap (zswap) is already on in this kernel"
    fi
    params=${params# }

    if [ -z "$params" ]; then
        if [ -f "$GRUB_DROPIN" ]; then
            rm -f "$GRUB_DROPIN"
            update-grub >/dev/null 2>&1
            ok "removed $GRUB_DROPIN (no longer needed)"
        fi
        return
    fi
    if [ ! -f /etc/default/grub ] || ! command -v update-grub >/dev/null; then
        skip "this install does not boot through GRUB, boot options not added"
        return
    fi
    mkdir -p /etc/default/grub.d
    cat > "$GRUB_DROPIN" <<EOF
# Yoga Slim 7 14IMH9 (written by yoga-slim7-ubuntu/install.sh).
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT $params"
EOF
    if update-grub >/dev/null 2>&1; then
        ok "boot options set: $params (active after the next reboot)"
    else
        rm -f "$GRUB_DROPIN"
        warn "update-grub failed, boot options removed again"
    fi
}

# ---------------------------------------------------------------------------
# Hibernation writes the whole memory to swap and powers off, so it needs a
# swap area larger than the RAM and a boot option that tells the
# kernel where to find the saved image.

# Finds a swap area of at least the wanted size. If there is none, the
# swapfile is replaced by a larger one (or /swap.img is created).
# Sets HIB_SWAP and HIB_SWAP_TYPE; returns non-zero after a WARN on failure.
make_swapfile() {
    # make_swapfile PATH SIZE_GIB
    rm -f "$1"
    fallocate -l "${2}G" "$1" && chmod 600 "$1" && mkswap -q "$1" >/dev/null
}

ensure_hibernate_swap() {
    local need_gib=$1 name type size file="" replacing=0
    # A swap area reports slightly less than the size of its file (one header page).
    local need_bytes=$(( need_gib * 1073741824 - 1048576 ))
    while read -r name type size; do
        [ -n "$name" ] || continue
        if [ "$size" -ge "$need_bytes" ]; then
            HIB_SWAP=$name
            HIB_SWAP_TYPE=$type
            skip "$name is already large enough ($(( (size + 1048576) / 1073741824 )) GiB)"
            return 0
        fi
        [ "$type" = file ] && [ -z "$file" ] && file=$name
    done < <(swapon --show=NAME,TYPE,SIZE --bytes --noheadings 2>/dev/null)

    if [ -n "$file" ]; then replacing=1; else file=/swap.img; fi
    local dir tmp="$file.tmp" avail_kib fstype space_gib
    dir=$(dirname "$file")
    fstype=$(findmnt -no FSTYPE -T "$dir" 2>/dev/null)
    if [ "$fstype" != ext4 ]; then
        warn "$dir is on $fstype; this script only builds a hibernation swapfile on ext4"
        return 1
    fi
    # Replacing a swapfile needs room for a temporary one as well, and 10 GiB must stay free.
    space_gib=$(( need_gib * (replacing + 1) + 10 ))
    avail_kib=$(df --output=avail -k "$dir" | tail -n 1 | tr -d ' ')
    if [ "$avail_kib" -lt $(( space_gib * 1048576 )) ]; then
        warn "not enough free disk space for a ${need_gib} GiB swapfile (free: $((avail_kib / 1048576)) GiB, needed while it is built: $space_gib GiB)"
        return 1
    fi

    if [ "$replacing" -eq 1 ]; then
        # Whatever is in swap right now has to go somewhere while the old file
        # is switched off. A temporary swapfile takes it, so this works even
        # when memory is nearly full.
        if ! make_swapfile "$tmp" "$need_gib" || ! swapon -p 1 "$tmp"; then
            rm -f "$tmp"
            warn "could not create a temporary swapfile; the existing swap was left untouched"
            return 1
        fi
        if ! swapoff "$file"; then
            swapoff "$tmp" 2>/dev/null
            rm -f "$tmp"
            warn "could not switch off $file; the existing swap was left untouched"
            return 1
        fi
    fi
    if ! make_swapfile "$file" "$need_gib" || ! swapon -p 100 "$file"; then
        if [ "$replacing" -eq 1 ]; then
            warn "could not create the new $file. Swap is running from $tmp until the next reboot; run this script again before rebooting."
        else
            warn "could not create ${need_gib} GiB swapfile $file"
        fi
        return 1
    fi
    if [ "$replacing" -eq 1 ]; then
        if swapoff "$tmp"; then
            rm -f "$tmp"
        else
            warn "the temporary swapfile $tmp is still in use; it is harmless, delete it after the next reboot"
        fi
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

    local mem_kib need_gib uuid offset params
    mem_kib=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    # SWAP_PERCENT of the RAM, rounded up to a whole GiB. The image needs up to
    # the RAM size; the rest is room for what is already swapped out.
    need_gib=$(( (mem_kib * SWAP_PERCENT / 100 + 1048575) / 1048576 ))

    ensure_hibernate_swap "$need_gib" || return

    if [ "$HIB_SWAP_TYPE" = file ]; then
        uuid=$(findmnt -no UUID -T "$HIB_SWAP" 2>/dev/null)
        # Where the file starts on the disk, counted in filesystem blocks.
        offset=$(filefrag -v "$HIB_SWAP" 2>/dev/null | awk '$1 == "0:" { gsub(/\./, "", $4); print $4; exit }')
        case "$offset" in
            ''|*[!0-9]*) warn "could not read where $HIB_SWAP starts on the disk; hibernation was not set up"; return ;;
        esac
        params="resume=UUID=$uuid resume_offset=$offset"
        # Tell the running kernel as well. Otherwise a swapfile that was just
        # replaced could not be hibernated to until the next reboot, and closing
        # the lid would leave the laptop running.
        if [ -w /sys/power/resume_offset ]; then
            echo "$offset" > /sys/power/resume_offset 2>/dev/null \
                || warn "could not update the running kernel; reboot before closing the lid"
        fi
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
    install -D -m 755 "$KIT_DIR/files/yoga-scale" "$SCALE_HELPER" \
        && ok "installed $SCALE_HELPER (in-between screen sizes such as 110% or 120%)" \
        || warn "could not install $SCALE_HELPER"
    sed -i 's/\r$//' "$SCALE_HELPER" 2>/dev/null
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
    # An earlier run already set this, and it has a different value now: you
    # changed it back yourself. Your choice wins; do not force it again.
    if grep -qs "^$1|$2|" "$GS_BACKUP"; then
        skip "$2 (you set it to $old after the first run; left alone)"
        return
    fi
    printf '%s|%s|%s\n' "$1" "$2" "$old" >> "$GS_BACKUP"
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
# Fonts (optional, only with --windows-fonts). Ubuntu's own fonts are the
# default. Coming from Windows, Ubuntu's text looks unfamiliar and, in browsers
# and Electron applications on this OLED panel, slightly coloured at the edges.
#  - Selawik (Microsoft's open stand-in for Segoe UI, shipped in this kit)
#    becomes the interface font and stands in wherever Segoe UI is asked for.
#  - Consolas becomes the code and terminal font when it is installed.
#  - Smoothing changes from colour (made for LCD stripes) to plain greyscale.
# Everything is per user: files go into your home folder, written as you.

# user_copy SOURCE DEST: installs a file into the user's home as the user.
# Returns 0 when written, 1 when it was already identical, 2 on failure.
user_copy() {
    [ ! -L "$2" ] || return 2
    if as_user test -f "$2" && as_user cmp -s - "$2" < "$1"; then
        return 1
    fi
    as_user sh -c 'umask 022; cat > "$1"' sh "$2" < "$1" || return 2
}

setup_fonts() {
    say "Fonts (Windows-like, cleaner on the OLED panel)"
    if [ "$WITH_FONTS" -eq 0 ]; then
        skip "Ubuntu's own fonts left as they are (add --windows-fonts for Selawik and Consolas)"
        return
    fi
    if ! find_desktop_user; then
        warn "no desktop session found. Run this script with sudo from a terminal inside GNOME to set up the fonts."
        return
    fi
    local src="$KIT_DIR/files/fonts" font_dir="$DESK_HOME/.local/share/fonts/selawik"
    local conf_dir="$DESK_HOME/.config/fontconfig/conf.d" f rc written=0
    if [ ! -f "$src/selawik/selawk.ttf" ] || [ ! -f "$src/$FONT_CONF_NAME" ]; then
        warn "the font files are missing from the kit (files/fonts)"
        return
    fi
    for f in "$DESK_HOME/.local" "$DESK_HOME/.local/share" "$DESK_HOME/.local/share/fonts" "$font_dir" \
             "$DESK_HOME/.config" "$DESK_HOME/.config/fontconfig" "$conf_dir"; do
        if [ -L "$f" ]; then
            warn "$f is a link; fonts left untouched"
            return
        fi
    done
    as_user mkdir -p "$font_dir" "$conf_dir" || { warn "could not create the font folders"; return; }

    for f in "$src"/selawik/*.ttf "$src/selawik/LICENSE.txt"; do
        user_copy "$f" "$font_dir/$(basename "$f")"; rc=$?
        [ "$rc" -eq 0 ] && written=$((written + 1))
        [ "$rc" -eq 2 ] && { warn "could not install $(basename "$f")"; return; }
    done
    user_copy "$src/$FONT_CONF_NAME" "$conf_dir/$FONT_CONF_NAME"; rc=$?
    [ "$rc" -eq 0 ] && written=$((written + 1))
    [ "$rc" -eq 2 ] && { warn "could not install $FONT_CONF_NAME"; return; }
    if [ "$written" -gt 0 ]; then
        as_user fc-cache -f "$DESK_HOME/.local/share/fonts" 2>/dev/null
        ok "Selawik and the font rules installed in your home folder ($written file(s) written)"
    else
        skip "Selawik and the font rules (already in place)"
    fi

    mkdir -p "$STATE_DIR"
    echo "$DESK_USER" > "$GS_USER_FILE"
    local iface=org.gnome.desktop.interface
    gs_set $iface font-name "'Selawik 11'"
    gs_set $iface document-font-name "'Selawik 11'"
    gs_set org.gnome.desktop.wm.preferences titlebar-font "'Selawik Semi-Bold 11'"
    gs_set $iface font-antialiasing "'grayscale'"
    if as_user fc-list Consolas 2>/dev/null | grep -q .; then
        gs_set $iface monospace-font-name "'Consolas 12'"
    else
        skip "code font left as it is: Consolas is not installed. It comes with Microsoft's core fonts, which ask you to accept a licence: sudo apt install ttf-mscorefonts-installer, then run this script again."
    fi
    FONTS_READY=1
}

remove_fonts() {
    local user home f
    user=$(cat "$GS_USER_FILE" 2>/dev/null)
    [ -n "$user" ] || user=${SUDO_USER:-}
    [ -n "$user" ] && [ "$user" != root ] || return 0
    home=$(getent passwd "$user" | cut -d: -f6)
    f=$home/.config/fontconfig/conf.d/$FONT_CONF_NAME
    [ -f "$f" ] && [ ! -L "$f" ] || return 0
    sudo -u "$user" rm -f "$f" && ok "removed $f" || warn "could not remove $f"
    echo "   note  the Selawik font files in $home/.local/share/fonts/selawik were kept; they are harmless"
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
        if ! git -c advice.detachedHead=false clone -q --depth 1 --branch "$SPEAKER_TOOL_TAG" "$SPEAKER_TOOL_REPO" "$SPEAKER_TOOL_DIR"; then
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

    # Howdy needs three face-recognition model files that its package does not ship; the
    # first "howdy add" otherwise stops and asks you to run this download script.
    local dlib=/etc/howdy/dlib-data f missing=0
    for f in dlib_face_recognition_resnet_model_v1.dat mmod_human_face_detector.dat shape_predictor_5_face_landmarks.dat; do
        [ -s "$dlib/$f" ] || missing=1
    done
    if [ "$missing" -eq 0 ]; then
        skip "face-recognition model files (already downloaded)"
    elif [ ! -x "$dlib/install.sh" ]; then
        warn "$dlib/install.sh not found; the first 'sudo howdy add' will say how to get the model files"
    else
        apt_install_each bzip2 >/dev/null
        echo "   ...   downloading Howdy's face-recognition model files (about 30 MB)"
        if (cd "$dlib" && ./install.sh >/dev/null 2>&1); then
            ok "face-recognition model files downloaded into $dlib"
        else
            warn "could not download the model files; run: cd $dlib && sudo ./install.sh"
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
    setup_ir_emitter
    setup_faceid_popup
}

# howdy_stamps set|restore: edits the [rubberstamps] section of the Howdy config.
#   set:     turns rubberstamps on with only the "faceid" rule (when they were off), or adds
#            the rule to the existing ones (when they were on); the old values go to STAMP_STATE.
#   restore: puts the saved values back.
howdy_stamps() {
    python3 - "$1" "$HOWDY_CONFIG" "$STAMP_STATE" <<'PY'
import json, os, re, sys
mode, path, state_path = sys.argv[1:4]
lines = open(path, encoding="utf-8").read().split("\n")
start = next((i for i, l in enumerate(lines) if l.strip() == "[rubberstamps]"), None)
if start is None:
    sys.exit("no [rubberstamps] section")
end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("[")), len(lines))
sec = lines[start + 1:end]

def find(key):
    for i, l in enumerate(sec):
        if re.match(rf"^{key}\s*=", l):
            j = i + 1
            while j < len(sec) and sec[j][:1] in (" ", "\t") and sec[j].strip():
                j += 1
            return i, j
    return None

e, r = find("enabled"), find("stamp_rules")
if e is None or r is None:
    sys.exit("[rubberstamps] lacks enabled or stamp_rules")
rule = "\tfaceid\t\t1s\t\tfailsafe"
if mode == "set":
    if any(l.strip().startswith("faceid") for l in sec[r[0]:r[1]]):
        sys.exit(0)                                   # already set
    was_on = sec[e[0]].split("=", 1)[1].strip().lower() == "true"
    json.dump({"enabled": sec[e[0]], "rules": sec[r[0]:r[1]]}, open(state_path, "w"))
    new_rules = sec[r[0]:r[1]] + [rule] if was_on else ["stamp_rules =", rule]
    new_enabled = "enabled = true"
else:
    if not os.path.exists(state_path):
        sys.exit(0)
    saved = json.load(open(state_path))
    new_rules, new_enabled = saved["rules"], saved["enabled"]
# replace the later block first so the earlier indexes stay valid
for (a, b), repl in sorted([(r, new_rules), ((e[0], e[0] + 1), [new_enabled])], reverse=True):
    sec[a:b] = repl
lines[start + 1:end] = sec
tmp = path + ".kit-tmp"
open(tmp, "w", encoding="utf-8").write("\n".join(lines))
os.chmod(tmp, os.stat(path).st_mode & 0o7777)
os.replace(tmp, path)
if mode == "restore":
    os.remove(state_path)
PY
}

setup_faceid_popup() {
    local src="$KIT_DIR/files/howdy-faceid"
    if ! dpkg-query -W -f='${Status}' howdy-gtk 2>/dev/null | grep -q 'install ok installed'; then
        skip "Face ID popup: howdy-gtk is not installed"
        return
    fi
    if ! python3 -c 'import gi; gi.require_version("PangoCairo", "1.0")' 2>/dev/null; then
        apt_install_each gir1.2-pango-1.0 || { warn "Face ID popup: PangoCairo is missing; Howdy's own popup kept"; return; }
    fi
    # Howdy's own popup is moved aside, so package updates land there and not over ours
    if ! dpkg-divert --list "$POPUP_FILE" | grep -q .; then
        dpkg-divert --quiet --local --rename --divert "$POPUP_DIVERTED" --add "$POPUP_FILE" \
            || { warn "Face ID popup: could not divert $POPUP_FILE"; return; }
    fi
    install -m 644 "$src/authsticky.py" "$POPUP_FILE"
    install -m 644 "$src/faceid.py" "$STAMP_FILE"
    mkdir -p "$STATE_DIR"
    if howdy_stamps set; then
        ok "Face ID-style popup installed (Howdy's own is kept as $POPUP_DIVERTED)"
    else
        warn "Face ID popup installed, but the success tick could not be enabled in $HOWDY_CONFIG"
    fi
}

remove_faceid_popup() {
    if dpkg-divert --list "$POPUP_FILE" | grep -q .; then
        rm -f "$POPUP_FILE"
        dpkg-divert --quiet --local --rename --remove "$POPUP_FILE" && ok "Howdy's own popup restored"
    fi
    [ -f "$STAMP_FILE" ] && rm -f "$STAMP_FILE" && ok "removed $STAMP_FILE"
    if [ -f "$STAMP_STATE" ] && [ -f "$HOWDY_CONFIG" ]; then
        howdy_stamps restore && ok "Howdy rubberstamp settings put back"
    fi
}

# The sysfs folder of the USB camera with the given vendor:product, if it is connected.
usb_device_dir() {
    local d
    for d in /sys/bus/usb/devices/*; do
        [ -f "$d/idVendor" ] && [ -f "$d/idProduct" ] || continue
        [ "$(cat "$d/idVendor"):$(cat "$d/idProduct")" = "$1" ] && { echo "$d"; return 0; }
    done
    return 1
}

# The tool's name for the infrared node: usb-VID:PID-SERIAL-ifNN-indexN (its v7 format).
ir_device_key() {
    local dev="$1" node iface index serial
    serial=$(cat "$dev/serial" 2>/dev/null || echo 0)
    for node in "$dev"/*:*/video4linux/video*; do
        [ -e "$node" ] || continue
        v4l2-ctl -d "/dev/$(basename "$node")" --list-formats 2>/dev/null | grep -q "'GREY'" || continue
        iface=$(cat "$(dirname "$(dirname "$node")")/bInterfaceNumber" 2>/dev/null) || continue
        index=$(cat "$node/index" 2>/dev/null || echo 0)
        echo "usb-$IR_CAMERA_ID-$serial-if$iface-index$index"
        return 0
    done
    return 1
}

setup_ir_emitter() {
    local dev key user home cfg tmp
    if ! dev=$(usb_device_dir "$IR_CAMERA_ID"); then
        skip "infrared light: camera $IR_CAMERA_ID not found (the saved setting is for this laptop's camera only)"
        return
    fi
    if [ "$(uname -m)" != x86_64 ]; then
        warn "infrared light: the kit only carries the x86-64 build of linux-enable-ir-emitter"
        return
    fi

    # 1. the tool, from its GitHub release, checked against the SHA-256 recorded above
    if [ -x "$IR_TOOL" ] && "$IR_TOOL" --version 2>/dev/null | grep -qF "$IR_TOOL_VERSION"; then
        skip "linux-enable-ir-emitter $IR_TOOL_VERSION (already installed)"
    else
        tmp=$(mktemp -d)
        if ! curl -fsSLo "$tmp/tool.tar.gz" "$IR_TOOL_URL"; then
            warn "infrared light: could not download linux-enable-ir-emitter"
            rm -rf "$tmp"; return
        fi
        if [ "$(sha256sum "$tmp/tool.tar.gz" | cut -d' ' -f1)" != "$IR_TOOL_SHA256" ]; then
            warn "infrared light: the linux-enable-ir-emitter download does not match its recorded checksum; not installed"
            rm -rf "$tmp"; return
        fi
        tar -C "$tmp" --no-same-owner -xzf "$tmp/tool.tar.gz" linux-enable-ir-emitter
        install -m 755 "$tmp/linux-enable-ir-emitter" "$IR_TOOL"
        rm -rf "$tmp"
        mkdir -p "$STATE_DIR"
        touch "$IR_TOOL_MARKER"
        ok "linux-enable-ir-emitter $IR_TOOL_VERSION installed in $IR_TOOL"
    fi

    # 2. the setting that keeps the light on, in the user's own config (the tool reads the
    #    config of the user who is signing in). A config with content is never replaced.
    user=${SUDO_USER:-}
    if [ -z "$user" ] || [ "$user" = root ]; then
        warn "infrared light: run the script with sudo from your own account so the setting goes into your config"
        return
    fi
    home=$(getent passwd "$user" | cut -d: -f6)
    cfg=$home/.config/linux-enable-ir-emitter.toml
    if [ -s "$cfg" ]; then
        skip "infrared setting ($cfg already has one; kept)"
    elif ! key=$(ir_device_key "$dev"); then
        warn "infrared light: could not find the camera's infrared node; run: linux-enable-ir-emitter configure"
        return
    else
        install -d -o "$user" -g "$(id -gn "$user")" "$home/.config"
        printf '[["%s".savelist]]\nunit = %s\nselector = %s\ncontrol = %s\n' \
            "$key" "$IR_CONTROL_UNIT" "$IR_CONTROL_SELECTOR" "$IR_CONTROL_VALUE" > "$cfg"
        chown "$user:$(id -gn "$user")" "$cfg"
        chmod 664 "$cfg"
        mkdir -p "$STATE_DIR"
        echo "$cfg" > "$IR_CONFIG_MARKER"
        ok "infrared setting written to $cfg ($key)"
    fi

    # 3. switch the light on before every face scan: login, lock screen, sudo, polkit prompts
    if grep -qs "linux-enable-ir-emitter run" /etc/pam.d/common-auth; then
        skip "infrared light already switched on before each face scan"
    elif "$IR_TOOL" setup-howdy >/dev/null 2>&1 && grep -qs "linux-enable-ir-emitter run" /etc/pam.d/common-auth; then
        ok "infrared light switched on before each face scan (login, lock screen, sudo)"
    else
        warn "infrared light: 'linux-enable-ir-emitter setup-howdy' failed; run it yourself with sudo"
    fi
}

remove_ir_emitter() {
    if [ -x "$IR_TOOL" ] && grep -qs "linux-enable-ir-emitter run" /etc/pam.d/common-auth; then
        "$IR_TOOL" setup-howdy --undo >/dev/null 2>&1 && ok "infrared step removed from the login settings" \
            || warn "could not remove the infrared step; run: sudo linux-enable-ir-emitter setup-howdy --undo"
    fi
    if [ -f "$IR_CONFIG_MARKER" ]; then
        local cfg
        cfg=$(cat "$IR_CONFIG_MARKER")
        [ -f "$cfg" ] && rm -f "$cfg" && ok "removed $cfg"
        rm -f "$IR_CONFIG_MARKER"
    fi
    if [ -f "$IR_TOOL_MARKER" ]; then
        rm -f "$IR_TOOL" "$IR_TOOL_MARKER" && ok "removed $IR_TOOL"
    fi
}

remove_face_login() {
    remove_faceid_popup
    remove_ir_emitter
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

# ---------------------------------------------------------------------------
# Password keyring. GNOME keeps saved passwords (browser, Wi-Fi, app sign-ins)
# in a keyring that is normally encrypted with the login password. After a face
# login nothing has typed that password, so every application that needs the
# keyring asks for it. This makes a keyring WITHOUT a password the default one:
# no more prompts, but what is saved in it is not encrypted.
# Everything inside the home folder is read and written AS THE USER, never as
# root, and links are refused: root must not follow a link that sits in a
# folder the user controls.
keyring_is_passwordless() {
    # keyring_is_passwordless USER FILE
    # A keyring file without a password is plain text starting with [keyring];
    # an encrypted one is binary.
    [ ! -L "$2" ] && sudo -u "$1" test -f "$2" \
        && sudo -u "$1" head -c 9 "$2" 2>/dev/null | grep -q '^\[keyring\]$'
}

# A keyring name as gnome-keyring writes it; anything else is treated as "login".
valid_keyring_name() {
    # Checked as one whole string, so a second line cannot smuggle a valid-looking name past it.
    [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]]
}

# True when the folder sits on an encrypted (LUKS / dm-crypt) volume.
on_encrypted_disk() {
    local src
    src=$(findmnt -no SOURCE -T "$1" 2>/dev/null) || return 1
    src=${src%%\[*}                                  # btrfs shows /dev/x[/subvolume]
    [ -n "$src" ] && lsblk -nso TYPE "$src" 2>/dev/null | grep -qx crypt
}

setup_keyring() {
    say "Password keyring (no password prompts)"
    if [ "$KEEP_KEYRING" -eq 1 ]; then
        skip "left alone (--keep-keyring)"
        return
    fi
    local user=${SUDO_USER:-} home dir file pointer current
    if [ -z "$user" ] || [ "$user" = root ]; then
        warn "run this script with sudo from your own account to set up the keyring"
        return
    fi
    home=$(getent passwd "$user" | cut -d: -f6)
    dir=$home/.local/share/keyrings
    file=$dir/$KEYRING_NAME.keyring
    pointer=$dir/default

    if [ -L "$dir" ] || [ -L "$file" ] || [ -L "$pointer" ]; then
        warn "the keyring folder or one of its files is a link; left untouched"
        return
    fi
    current=$(sudo -u "$user" cat "$pointer" 2>/dev/null || true)
    valid_keyring_name "$current" || current=login

    if [ "$current" = "$KEYRING_NAME" ] && keyring_is_passwordless "$user" "$file"; then
        skip "the default keyring already has no password"
        return
    fi
    if sudo -u "$user" test -e "$file" && ! keyring_is_passwordless "$user" "$file"; then
        warn "$file exists and is password-protected; left untouched"
        return
    fi

    mkdir -p "$STATE_DIR"
    # Remember what was the default before, so --undo can put it back.
    [ -f "$KEYRING_BACKUP" ] || printf '%s' "$current" > "$KEYRING_BACKUP"

    sudo -u "$user" install -d -m 700 "$dir"
    if ! sudo -u "$user" test -e "$file"; then
        printf '[keyring]\ndisplay-name=Default keyring\nctime=%s\nmtime=0\nlock-on-idle=false\nlock-after=false\n' "$(date +%s)" \
            | sudo -u "$user" sh -c 'umask 077; cat > "$1"' sh "$file"
    fi
    printf '%s' "$KEYRING_NAME" | sudo -u "$user" sh -c 'umask 077; cat > "$1"' sh "$pointer"

    if [ "$(sudo -u "$user" cat "$pointer" 2>/dev/null)" = "$KEYRING_NAME" ] && keyring_is_passwordless "$user" "$file"; then
        ok "new saved passwords go to a keyring without a password (active after you log out and in)"
        if on_encrypted_disk "$home"; then
            echo "   note  they are not encrypted inside the keyring; your encrypted disk is what protects them"
        else
            warn "this disk is NOT encrypted, so anyone who can read it (for example by booting from a USB stick) can read the passwords saved in $file. Undo with: sudo bash install.sh --undo, or reinstall with disk encryption."
        fi
    else
        warn "could not write the keyring files in $dir"
    fi
}

restore_keyring() {
    [ -f "$KEYRING_BACKUP" ] || return 0
    local user=${SUDO_USER:-} home pointer previous
    [ -n "$user" ] && [ "$user" != root ] || { warn "keyring not restored: run --undo with sudo from your own account"; return 1; }
    home=$(getent passwd "$user" | cut -d: -f6)
    pointer=$home/.local/share/keyrings/default
    previous=$(cat "$KEYRING_BACKUP")
    valid_keyring_name "$previous" || previous=login
    if [ -L "$pointer" ] || [ -L "$(dirname "$pointer")" ]; then
        warn "keyring not restored: $pointer is a link"
        return 1
    fi
    if printf '%s' "$previous" | sudo -u "$user" sh -c 'umask 077; cat > "$1"' sh "$pointer"; then
        ok "default keyring set back to '$previous'"
    else
        warn "could not write $pointer"
        return 1
    fi
    rm -f "$KEYRING_BACKUP"
    echo "   note  $home/.local/share/keyrings/$KEYRING_NAME.keyring was kept: it holds the passwords saved meanwhile"
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
    for f in "$AUDIO_CONF" "$SYSCTL_CONF" "$UDEV_RULES" "$NM_CONF" "$GRUB_DROPIN" "$AUTO_UNIT" "$SLEEP_HOOK" "$HELPER" "$SCALE_HELPER" "$CONFIG" \
             "$HIB_GRUB" "$HIB_INITRAMFS" "$HIB_DRACUT" "$LID_CONF" "$SLEEP_CONF"; do
        if [ -e "$f" ]; then rm -f "$f" && ok "removed $f"; else skip "$f (not present)"; fi
    done
    systemctl daemon-reload
    systemctl kill -s HUP systemd-logind 2>/dev/null
    udevadm control --reload 2>/dev/null
    nmcli general reload conf >/dev/null 2>&1
    [ "$had_grub" -eq 1 ] && command -v update-grub >/dev/null && update-grub >/dev/null 2>&1
    command -v update-initramfs >/dev/null && update-initramfs -u -k all >/dev/null 2>&1
    restore_keyring
    remove_claude
    remove_face_login
    remove_speaker_sound
    remove_fonts
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
setup_fonts
tune_speaker_sound
setup_face_login
setup_keyring
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
    echo "  5. sudo -k true                     (should say \"Identified face\"; see README if it times out)"
fi
if [ "$CLAUDE_READY" -eq 1 ]; then
    echo "  -  open Claude from the application menu and sign in; in a terminal, run: claude"
fi
if [ "$FONTS_READY" -eq 1 ]; then
    echo "  -  applications that were open keep their old fonts until you restart them"
fi
