#!/usr/bin/env bash
# What the installer decides on laptops and systems other than the one it was
# written on. Each case builds a made-up machine in a throwaway folder.
set -u
. "$(dirname "$0")/helpers.sh"

machine() {
    R=$W/$1
    mkdir -p "$R/sys/class/dmi/id" "$R/sys/class/drm" "$R/sys/class/power_supply" "$R/sys/class/nvme" \
             "$R/sys/devices" "$R/sys/bus/usb/devices" "$R/proc/asound" "$R/etc" "$R/out"
}
dmi()     { echo "$1" > "$R/sys/class/dmi/id/sys_vendor"; echo "$2" > "$R/sys/class/dmi/id/product_name"; echo "$3" > "$R/sys/class/dmi/id/product_version"; }
cpu()     { printf 'processor\t: 0\nvendor_id\t: %s\n' "$1" > "$R/proc/cpuinfo"; [ "${2:-}" = hybrid ] && mkdir -p "$R/sys/devices/cpu_atom"; return 0; }
gpu()     { local i=0 v; for v in "$@"; do mkdir -p "$R/sys/class/drm/card$i/device"; echo "$v" > "$R/sys/class/drm/card$i/device/vendor"; i=$((i + 1)); done; }
battery() { mkdir -p "$R/sys/class/power_supply/BAT0"; }
nvme()    { mkdir -p "$R/sys/class/nvme/nvme0"; }
codec()   { mkdir -p "$R/proc/asound/card0"; printf 'Codec: Test\nSubsystem Id: %s\n' "$1" > "$R/proc/asound/card0/codec#0"; }
panel()   { mkdir -p "$R/sys/class/drm/card0-eDP-1"; printf '\0\377\377\377\377\377\377\0\1\2\3\4\5\0\0\0\376\0%s\n   \0\0' "$1" > "$R/sys/class/drm/card0-eDP-1/edid"; }
camera()  { local d=$R/sys/bus/usb/devices/3-$1; mkdir -p "$d/3-$1:1.0"; echo "$2" > "$d/idVendor"; echo "$3" > "$d/idProduct"; echo "$4" > "$d/removable"; echo "$5" > "$d/3-$1:1.0/bInterfaceClass"; }
os()      { printf 'ID=%s\nID_LIKE="%s"\nVERSION_ID="%s"\nPRETTY_NAME="%s"\n' "$1" "$2" "$3" "$4" > "$R/etc/os-release"; }

# decide: runs the detection and the hardware-dependent steps on machine $R.
decide() {
    (
        export YOGA_TEST_ROOT=$R
        FORCE=${FORCE:-0}; WITH_LPMD=1; KIT_DIR=$KIT; OPT_DIR=$R/out/opt; AUDIO_CONF=$R/out/audio.conf; NEED_REBOOT=0
        eval "$(sed -n '/^LPMD_PACKAGE=/,/^OS_NAME=""/p' "$KIT/install.sh")"
        eval "$(functions detect_hardware refuse check_machine builtin_cameras find_tuning_file fix_speakers install_packages \
            | sed 's|/run/casper|/nonexistent|; s|grep -q casper /proc/cmdline|false|; s|findmnt -no FSTYPE /|echo ext4|')"
        uname() { if [ "${1:-}" = -m ]; then echo "${ARCH:-x86_64}"; else echo 6.8.0-test; fi; }
        pkg_installed() { case " ${INSTALLED:-} " in *" $1 "*) return 0 ;; esac; return 1; }
        pkg_in_archive() { case " ${MISSING:-} " in *" $1 "*) return 1 ;; esac; return 0; }
        apt-get() { [ "$1" = install ] && WANT="$WANT ${*: -1}"; return 0; }
        update-initramfs() { :; }
        modinfo() { [ "$2" = "${HDA_MODULE:-snd-sof-intel-hda-generic}" ] && echo "hda_model:Use the given HDA board model. (charp)"; }
        check_machine || exit 1
        WANT=""
        install_packages > "$R/out/pkglog" 2>&1
        echo "packages:$WANT"
        grep -E 'skip|WARN' "$R/out/pkglog"
        echo "cameras: $(builtin_cameras | tr '\n' ' ')"
        echo "tuning file: $(find_tuning_file > /dev/null && echo found || echo none)"
        fix_speakers
        [ -f "$AUDIO_CONF" ] && echo "audio option: $(tail -n 1 "$AUDIO_CONF")"
        echo "oled=$HW_OLED hybrid=$HW_HYBRID verified=$HW_VERIFIED"
    ) 2>&1
}

# --- an AMD ThinkPad with an LCD screen on Ubuntu 24.04
machine a; dmi LENOVO 21K3CTO1WW "ThinkPad T14 Gen 5"; cpu AuthenticAMD; gpu 0x1002; battery; nvme
codec 0x17aa2318; panel "B140UAN04.3"; camera 5 5986 2142 fixed 0e; os ubuntu debian 24.04 "Ubuntu 24.04.3 LTS"
out=$(MISSING="radeontop" decide)
has   "AMD ThinkPad: named"                 "$out" "LENOVO ThinkPad T14 Gen 5 (21K3CTO1WW), Ubuntu 24.04.3 LTS"
has   "AMD ThinkPad: not a verified model"  "$out" "not a model the kit was verified on"
has   "AMD ThinkPad: AMD video decoder"     "$out" "mesa-va-drivers"
lacks "AMD ThinkPad: no Intel video driver" "$out" "intel-media-va-driver"
lacks "AMD ThinkPad: no Intel thermald"     "$out" "thermald"
lacks "AMD ThinkPad: no intel-lpmd"         "$out" "intel-lpmd"
has   "AMD ThinkPad: missing package is skipped, not an error" "$out" "skip  radeontop (not offered by this Ubuntu release)"
has   "AMD ThinkPad: built-in camera found" "$out" "cameras: 5986:2142"
has   "AMD ThinkPad: no speaker fix"        "$out" "no speaker fix is known, or needed"
has   "AMD ThinkPad: no Dolby file"         "$out" "tuning file: none"
has   "AMD ThinkPad: LCD"                   "$out" "oled=0 hybrid=0 verified=0"

# --- an Intel + NVIDIA Dell with a Samsung OLED screen, external webcam plugged in
machine b; dmi "Dell Inc." "XPS 15 9530" "Not Specified"; cpu GenuineIntel; gpu 0x8086 0x10de; battery; nvme
codec 0x10280beb; panel "ATNA56AC03-0"; camera 2 0c45 6732 fixed 0e; camera 7 046d 085c removable 0e; os ubuntu debian 26.04 "Ubuntu 26.04.1 LTS"
out=$(decide)
has   "Dell: model shown once"              "$out" "Dell Inc. XPS 15 9530, Ubuntu 26.04.1 LTS"
has   "Dell: both graphics chips seen"      "$out" "graphics: intel nvidia"
has   "Dell: OLED recognised"               "$out" "ATNA56AC03-0 (OLED)"
has   "Dell: Intel video driver"            "$out" "intel-media-va-driver"
has   "Dell: thermald"                      "$out" "thermald"
lacks "Dell: no intel-lpmd on an older CPU" "$out" "intel-lpmd"
has   "Dell: only the built-in camera"      "$out" "cameras: 0c45:6732 "
lacks "Dell: external webcam left alone"    "$out" "046d:085c"
has   "Dell: OLED"                          "$out" "oled=1 hybrid=0 verified=0"

# --- the verified model, but on Ubuntu 24.04 with its older kernel, and TLP installed
machine c; dmi LENOVO 83CV "Yoga Slim 7 14IMH9"; cpu GenuineIntel hybrid; gpu 0x8086; battery; nvme
codec 0x17aa38d8; panel "ATNA40CT01-0"; camera 9 04f2 b7f5 fixed 0e; os ubuntu debian 24.04 "Ubuntu 24.04.3 LTS"
out=$(INSTALLED="tlp" HDA_MODULE=snd-sof-intel-hda-common decide)
has   "83CV on 24.04: verified model"       "$out" "a model the whole kit was verified on"
has   "83CV on 24.04: intel-lpmd"           "$out" "intel-lpmd"
lacks "83CV on 24.04: TLP keeps its job"    "$out" "packages: firmware-sof-signed alsa-ucm-conf alsa-utils powertop lm-sensors iw fwupd v4l-utils intel-media-va-driver vainfo intel-gpu-tools thermald nvme-cli power-profiles-daemon"
has   "83CV on 24.04: says why"             "$out" "another power tool is installed"
has   "83CV on 24.04: Dolby file found"     "$out" "tuning file: found"
has   "83CV on 24.04: option on the older kernel's module" "$out" "audio option: options snd-sof-intel-hda-common hda_model=alc287-yoga9-bass-spk-pin"

# --- the same laptop on a current kernel, sound through the classic driver
machine c2; dmi LENOVO 83CV "Yoga Slim 7 14IMH9"; cpu GenuineIntel hybrid; gpu 0x8086; battery
codec 0x17aa38d8; os ubuntu debian 26.10 "Ubuntu 26.10"
mkdir -p "$R/sys/class/sound/card0/device" "$R/sys/drv/snd_hda_intel"; ln -s "$R/sys/drv/snd_hda_intel" "$R/sys/class/sound/card0/device/driver"
out=$(decide)
has   "classic sound driver: its own option" "$out" "audio option: options snd-hda-intel model=alc287-yoga9-bass-spk-pin"

# --- systems the kit refuses
machine d; dmi ASUS "PRIME B650" "System Version"; cpu AuthenticAMD; gpu 0x1002; os ubuntu debian 26.10 "Ubuntu 26.10"
has   "desktop PC refused"                  "$(decide)" "STOP  no battery found"
machine e; dmi LENOVO 83CV "Yoga Slim 7 14IMH9"; cpu GenuineIntel hybrid; battery; os fedora "" 43 "Fedora Linux 43"
has   "Fedora refused"                      "$(decide)" "STOP  this is Fedora Linux 43"
machine f; dmi HP "HP EliteBook 840 G8" ""; cpu GenuineIntel; gpu 0x8086; battery; os ubuntu debian 22.04 "Ubuntu 22.04.5 LTS"
has   "Ubuntu 22.04 refused"                "$(decide)" "STOP  this is Ubuntu 22.04; the kit needs 24.04 or later"
out=$(FORCE=1 decide)
has   "Ubuntu 22.04 with --force: warned"   "$out" "WARN  this is Ubuntu 22.04"
has   "Ubuntu 22.04 with --force: goes on"  "$out" "HP HP EliteBook 840 G8, Ubuntu 22.04.5 LTS"
out=$(ARCH=aarch64 decide)
has   "ARM machine refused"                 "$out" "STOP  this is a aarch64 machine"

# --- an Ubuntu derivative
machine g; dmi HP "HP EliteBook 840 G8" ""; cpu GenuineIntel; gpu 0x8086; battery; codec 0x103c880d; os linuxmint "ubuntu debian" 22.1 "Linux Mint 22.1"
out=$(decide)
has   "Mint: warned as untested"            "$out" "is built on Ubuntu but is not Ubuntu itself"
has   "Mint: goes on"                       "$out" "packages: firmware-sof-signed"
has   "Mint: screen unknown is not OLED"    "$out" "oled=0"

finish
