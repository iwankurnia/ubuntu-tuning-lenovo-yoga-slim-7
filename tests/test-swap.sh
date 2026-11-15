#!/usr/bin/env bash
# Replacing the swapfile and keeping hibernation pointed at it, including the
# runs that are interrupted or fail half way.
set -u
. "$(dirname "$0")/helpers.sh"

# swap_case: runs ensure_hibernate_swap for a 22 GiB target.
#   SWAPS  the active swap areas, as "name type bytes" lines
#   FAIL   a command to make fail: swapon, swapoff, fallocate:<file name>
#   AVAIL  free disk space in KiB, or EMPTY for "cannot be read"
swap_case() {
    (
        FSTAB_BACKUP=$W/fstab.bak; HIB_SWAP=""; HIB_SWAP_TYPE=""; HIB_SWAP_REPLACED=0
        : > "$W/fstab"
        swapon() {
            if [ "$1" = "--show=NAME,TYPE,SIZE" ]; then printf '%s' "${SWAPS:-}"
            else echo "[swapon ${*: -1}]"; [ "${FAIL:-}" != swapon ]; fi
        }
        swapoff()   { echo "[swapoff $1]"; [ "${FAIL:-}" != swapoff ]; }
        fallocate() { echo "[fallocate $2 $3]"; [ "${FAIL:-}" != "fallocate:$(basename "$3")" ] && : > "$3"; }
        mkswap()    { :; }
        chmod()     { :; }
        cp()        { :; }
        findmnt()   { echo "${FSTYPE:-ext4}"; }
        df()        { [ "${AVAIL:-885000000}" = EMPTY ] && return 0; printf 'Avail\n%s\n' "${AVAIL:-885000000}"; }
        dirname()   { echo "$W"; }
        eval "$(functions make_swapfile ensure_hibernate_swap | sed "s|/etc/fstab|$W/fstab|g; s|file=/swap.img|file=$W/swap.img|")"
        ensure_hibernate_swap 22
        echo "rc=$? swap=${HIB_SWAP#"$W"} replaced=$HIB_SWAP_REPLACED left=$(ls "$W" | grep -c 'swap.img.tmp') fstab=$(grep -c 'pri=100' "$W/fstab")"
    ) 2>&1 | sed "s|$W||g"
    empty_work
}

OLD="$W/swap.img file 17179865088"$'\n'
BIG="$W/swap.img file 23622316032"$'\n'
TMP="$W/swap.img.tmp file 23622316032"$'\n'

out=$(SWAPS=$OLD swap_case)
has   "16 GiB in use: replaced"              "$out" "rc=0 swap=/swap.img replaced=1 left=0 fstab=1"
has   "16 GiB in use: temporary swap first"  "$out" "[swapon /swap.img.tmp]"
has   "16 GiB in use: sized 22 GiB"          "$out" "[fallocate 22G /swap.img]"

out=$(SWAPS=$BIG swap_case)
has   "already 22 GiB: left alone"           "$out" "rc=0 swap=/swap.img replaced=0"
lacks "already 22 GiB: nothing created"      "$out" "[fallocate"

out=$(SWAPS="" swap_case)
has   "no swap at all: created"              "$out" "rc=0 swap=/swap.img replaced=1 left=0 fstab=1"
lacks "no swap at all: no temporary file"    "$out" "swap.img.tmp"

out=$(FAIL=swapoff SWAPS=$OLD swap_case)
has   "old file cannot be switched off: untouched" "$out" "rc=1 swap= replaced=0 left=0"
has   "old file cannot be switched off: says so"   "$out" "the existing swap was left untouched"

out=$(AVAIL=40000000 SWAPS=$OLD swap_case)
has   "disk nearly full: refused"            "$out" "not enough free disk space"
lacks "disk nearly full: nothing created"    "$out" "[fallocate"

out=$(AVAIL=EMPTY SWAPS=$OLD swap_case)
has   "free space unreadable: refused"       "$out" "could not read the free disk space"
lacks "free space unreadable: nothing created" "$out" "[fallocate"

out=$(FSTYPE=btrfs SWAPS=$OLD swap_case)
has   "btrfs: refused"                       "$out" "only builds a hibernation swapfile on ext4"

: > "$W/swap.img.tmp"
out=$(SWAPS=$TMP swap_case)
has   "interrupted, only the temporary file active: finished properly" "$out" "rc=0 swap=/swap.img replaced=1 left=0 fstab=1"
lacks "interrupted: the temporary file is never the hibernation swap"  "$out" "swap=/swap.img.tmp"

: > "$W/swap.img.tmp"
out=$(SWAPS="$OLD$TMP" swap_case)
has   "interrupted, both active: finished properly" "$out" "rc=0 swap=/swap.img replaced=1 left=0"
lacks "interrupted, both active: no second temporary file" "$out" "[fallocate 22G /swap.img.tmp]"

out=$(FAIL=fallocate:swap.img SWAPS=$OLD swap_case)
has   "new file cannot be created: reported as half done" "$out" "rc=1 swap= replaced=1"
has   "new file cannot be created: swap still runs"       "$out" "Swap is running from /swap.img.tmp"

# hibernate_case: runs setup_hibernate as a whole.
hibernate_case() {
    (
        FSTAB_BACKUP=$W/fstab.bak; HIB_SWAP=""; HIB_SWAP_TYPE=""; HIB_SWAP_REPLACED=0; NEED_REBOOT=0
        LID_CONF=$W/lid.conf; SLEEP_CONF=$W/sleep.conf; HIB_GRUB=$W/91.cfg; HIB_DRACUT=$W/dracut.conf; HIB_INITRAMFS=$W/initramfs
        WITH_HIBERNATE=1; SWAP_PERCENT=150
        : > "$W/fstab"
        swapon() {
            if [ "$1" = "--show=NAME,TYPE,SIZE" ]; then printf '%s' "${SWAPS:-}"; else [ "${FAIL:-}" != swapon ]; fi
        }
        swapoff()   { [ "${FAIL:-}" != swapoff ]; }
        fallocate() { : > "$3"; }
        mkswap()    { :; }
        chmod()     { :; }
        cp()        { :; }
        findmnt()   { if [ "$2" = UUID ]; then echo "abcd-1234"; else echo ext4; fi; }
        df()        { printf 'Avail\n885000000\n'; }
        dirname()   { echo "$W"; }
        filefrag()  { [ "${FAIL:-}" = filefrag ] && return 1; printf ' ext: logical: physical: length:\n   0:        0..   32767:   %s..  9999:  32768:\n' "${OFFSET:-555000}"; }
        update-grub()      { echo "[update-grub]"; [ "${FAIL:-}" != update-grub ]; }
        update-initramfs() { echo "[update-initramfs]"; }
        systemctl() { :; }
        eval "$(functions make_swapfile ensure_hibernate_swap hibernate_unsafe | sed "s|/etc/fstab|$W/fstab|g; s|file=/swap.img|file=$W/swap.img|")"
        eval "$(functions setup_hibernate \
            | sed "s|/sys/power/state|$W/state|; s|/sys/kernel/security/lockdown|$W/lockdown|g; s|/etc/default/grub.d|$W|; s|\[ ! -f /etc/default/grub \]|false|; s|/proc/meminfo|$W/meminfo|; s|/sys/power/resume_offset|$W/resume_offset|g; s|/proc/cmdline|$W/cmdline|; s|/etc/initramfs-tools/conf.d|$W/none|; s|/usr/lib/dracut/modules.d|$W|; s|/etc/dracut.conf.d|$W|; s|command -v dracut|true|; s|command -v update-grub|true|; s|command -v update-initramfs|true|")"
        echo "freeze mem disk" > "$W/state"; echo "${LOCKDOWN:-[none] integrity}" > "$W/lockdown"
        echo "MemTotal: 15252768 kB" > "$W/meminfo"; : > "$W/resume_offset"
        setup_hibernate
        echo "lid=$([ -f "$LID_CONF" ] && echo kept || echo removed) grub=$([ -f "$HIB_GRUB" ] && grep -o 'resume_offset=[0-9]*' "$HIB_GRUB" || echo absent) kernel=$(cat "$W/resume_offset") reboot=$NEED_REBOOT"
    ) 2>&1 | sed "s|$W||g"
    empty_work
}

grub_line() { printf 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT resume=UUID=abcd-1234 resume_offset=%s"\n' "$1" > "$W/91.cfg"; }

grub_line 555000; echo "quiet resume=UUID=abcd-1234 resume_offset=555000" > "$W/cmdline"; : > "$W/dracut.conf"; : > "$W/lid.conf"
out=$(SWAPS=$BIG hibernate_case)
has   "re-run, nothing changed: skipped"      "$out" "boot option already in place"
lacks "re-run, nothing changed: boot menu not rebuilt" "$out" "[update-grub]"
has   "re-run, nothing changed: no reboot asked" "$out" "lid=kept grub=resume_offset=555000 kernel=555000 reboot=0"

grub_line 243138560; echo "quiet resume=UUID=abcd-1234 resume_offset=243138560" > "$W/cmdline"; printf '[Login]\nHandleLidSwitch=hibernate\n' > "$W/lid.conf"
out=$(OFFSET=777000 SWAPS=$OLD hibernate_case)
has   "swapfile replaced: everything follows" "$out" "lid=kept grub=resume_offset=777000 kernel=777000 reboot=1"
has   "swapfile replaced: lid action named"   "$out" "closing the lid keeps the action you chose (hibernate)"

echo old > "$W/91.cfg"; echo quiet > "$W/cmdline"; : > "$W/lid.conf"
out=$(FAIL=update-grub OFFSET=777000 SWAPS=$OLD hibernate_case)
has   "replaced, then update-grub fails: lid falls back to suspend" "$out" "lid=removed grub=resume_offset=777000"
has   "replaced, then update-grub fails: says how to repair"        "$out" "Run: sudo update-grub"

echo quiet > "$W/cmdline"; : > "$W/lid.conf"
out=$(FAIL=filefrag SWAPS=$OLD hibernate_case)
has   "replaced, position unreadable: lid falls back to suspend" "$out" "lid=removed"

echo old > "$W/91.cfg"; echo quiet > "$W/cmdline"; : > "$W/lid.conf"
out=$(FAIL=update-grub SWAPS=$BIG hibernate_case)
has   "nothing replaced, update-grub fails: lid not touched" "$out" "lid=kept"

echo quiet > "$W/cmdline"
out=$(LOCKDOWN="none [integrity] confidentiality" SWAPS=$OLD hibernate_case)
has   "Secure Boot on: stops before touching swap" "$out" "Secure Boot is on"
has   "Secure Boot on: nothing written"            "$out" "grub=absent"

finish
