#!/usr/bin/env bash
# The yoga-power tool on made-up batteries and chargers: switching between
# battery and mains settings, the charge limit on three kinds of laptop, the
# lid action, and the suspend report.
set -u
. "$(dirname "$0")/helpers.sh"

export YOGA_TEST_ROOT=$W
YP="$KIT/files/yoga-power"
BAT=$W/sys/class/power_supply/BAT0
ADP=$W/sys/class/power_supply/ADP0
TURBO=$W/sys/devices/system/cpu/intel_pstate/no_turbo

laptop() {
    empty_work
    mkdir -p "$BAT" "$ADP" "$W/sys/devices/system/cpu/intel_pstate" "$W/sys/power" "$W/sys/kernel/security" \
             "$W/proc/sys/vm" "$W/etc" "$W/var/log"
    echo Discharging > "$BAT/status"; echo 6400000 > "$BAT/power_now"; echo 47500000 > "$BAT/energy_now"; echo 73 > "$BAT/capacity"
    echo Mains > "$ADP/type"; echo 0 > "$ADP/online"
    echo 0 > "$TURBO"; echo 500 > "$W/proc/sys/vm/dirty_writeback_centisecs"
    echo "freeze mem disk" > "$W/sys/power/state"; echo "[none] integrity" > "$W/sys/kernel/security/lockdown"; echo "259:2" > "$W/sys/power/resume"
    printf 'MemTotal:       15252768 kB\nSwapTotal:      23068668 kB\n' > "$W/proc/meminfo"
}
flush() { cat "$W/proc/sys/vm/dirty_writeback_centisecs"; }

# --- battery and mains settings
laptop
out=$(bash "$YP" apply)
has  "on battery: battery settings"          "$out" "on battery:"
same "on battery: disk flush 60 s"           "$(flush)" "6000"
same "turbo left alone by default"           "$(cat "$TURBO")" "0"
echo 1 > "$ADP/online"
out=$(bash "$YP" apply)
has  "on mains: mains settings"              "$out" "on mains:"
same "on mains: disk flush 15 s"             "$(flush)" "1500"

laptop; echo 1 > "$TURBO"
bash "$YP" apply > /dev/null
same "turbo you switched off yourself stays off" "$(cat "$TURBO")" "1"

laptop; echo 'BATTERY_NO_TURBO=1' > "$W/etc/yoga-power.conf"
bash "$YP" apply > /dev/null
same "BATTERY_NO_TURBO=1: off on battery"    "$(cat "$TURBO")" "1"
echo 'BATTERY_NO_TURBO=0' > "$W/etc/yoga-power.conf"
bash "$YP" apply > /dev/null
same "option turned off again: turbo back on" "$(cat "$TURBO")" "0"
echo 'BATTERY_NO_TURBO=1' > "$W/etc/yoga-power.conf"; bash "$YP" apply > /dev/null
echo 1 > "$ADP/online"; bash "$YP" apply > /dev/null
same "charger plugged in: turbo back on"     "$(cat "$TURBO")" "0"

# --- measuring
laptop
out=$(bash "$YP" measure 1)
has  "measure: average draw"                 "$out" "average draw: 6.40 W"
has  "measure: hours left"                   "$out" "lasts about 7.4 hours"
echo 1 > "$ADP/online"
out=$(bash "$YP" measure 1 2>&1)
has  "measure refuses on mains"              "$out" "Unplug the charger first"

# --- charge limit: Lenovo IdeaPad and Yoga on a recent kernel
laptop; echo "Fast [Standard] Long_Life" > "$BAT/charge_types"
has  "Lenovo: reads full"                    "$(bash "$YP" battery status)" "full (charges to 100%)"
bash "$YP" battery conserve > /dev/null
same "Lenovo: writes the kernel's own spelling" "$(cat "$BAT/charge_types")" "Long_Life"
echo "Fast Standard [Long_Life]" > "$BAT/charge_types"
has  "Lenovo: reads conserve"                "$(bash "$YP" battery status)" "conserve (stops at about 80%)"
echo "Standard [Long Life]" > "$BAT/charge_types"
has  "Lenovo: the spelling with a space"     "$(bash "$YP" battery status)" "conserve (stops at about 80%)"

# --- charge limit: a percentage threshold (ThinkPad, ASUS, Dell and others)
laptop; echo 100 > "$BAT/charge_control_end_threshold"; echo "Standard [Adaptive]" > "$BAT/charge_types"
has  "threshold: reads full"                 "$(bash "$YP" battery status)" "full (charges to 100%)"
bash "$YP" battery conserve > /dev/null
same "threshold: conserve writes 80"         "$(cat "$BAT/charge_control_end_threshold")" "80"
has  "threshold: reads the percentage"       "$(bash "$YP" battery status)" "conserve (stops at 80%)"
bash "$YP" battery full > /dev/null
same "threshold: full writes 100"            "$(cat "$BAT/charge_control_end_threshold")" "100"

# --- charge limit: Lenovo on an older kernel
laptop; mkdir -p "$W/sys/bus/platform/drivers/ideapad_acpi/VPC2004:00"; echo 0 > "$W/sys/bus/platform/drivers/ideapad_acpi/VPC2004:00/conservation_mode"
bash "$YP" battery conserve > /dev/null
same "older Lenovo: conservation mode on"    "$(cat "$W/sys/bus/platform/drivers/ideapad_acpi/VPC2004:00/conservation_mode")" "1"

# --- charge limit: a laptop that offers none
laptop
has  "no control: says so"                   "$(bash "$YP" battery status)" "not available (this laptop offers no charge limit to Linux)"
out=$(bash "$YP" battery conserve 2>&1); rc=$?
same "no control: fails cleanly"             "$rc" "1"

# --- the lid
laptop
out=$(bash "$YP" lid hibernate 2>&1)
has  "lid hibernate when ready"              "$out" "closing the lid now does: hibernate"
has  "lid setting written"                   "$(cat "$W/etc/systemd/logind.conf.d/90-yoga-slim7-lid.conf")" "HandleLidSwitch=hibernate"
bash "$YP" lid suspend > /dev/null 2>&1
same "lid suspend removes the setting"       "$(ls "$W/etc/systemd/logind.conf.d" | wc -l)" "0"

laptop; echo "none [integrity] confidentiality" > "$W/sys/kernel/security/lockdown"
out=$(bash "$YP" lid hibernate 2>&1)
has  "Secure Boot on: lid hibernate refused" "$out" "Secure Boot is on"
same "Secure Boot on: nothing written"       "$([ -f "$W/etc/systemd/logind.conf.d/90-yoga-slim7-lid.conf" ] && echo written || echo none)" "none"

laptop; printf 'MemTotal:       15252768 kB\nSwapTotal:       4194300 kB\n' > "$W/proc/meminfo"; echo "0:0" > "$W/sys/power/resume"
out=$(bash "$YP" lid hibernate 2>&1)
has  "swap too small: refused"               "$out" "swap (3 GiB) is smaller than the memory (14 GiB)"
has  "no resume location: refused"           "$out" "no resume location is set"
out=$(bash "$YP" hibernate-test 2>&1)
has  "hibernate-test refuses too"            "$out" "Hibernation is not ready"

out=$(bash "$YP" lid banana 2>&1); rc=$?
same "unknown lid action rejected"           "$rc" "1"

# --- the suspend report
report() {
    awk -v t0=1000 -v t1="$1" -v r0=5000000 -v r1="$2" -v kind="$3" -v e0=40000000 -v e1="$4" -v ac0="$5" -v ac1=0 \
        "$(sed -n "/line=\$(awk/,/}')/p" "$KIT/files/yoga-sleep-report" | sed -n "/'BEGIN {/,/}')/p" | sed "1s/.*'BEGIN {/BEGIN {/; \$s/}')\$/}/")"
}
has  "suspend report"                        "$(report 29930 28067100000 suspend 38100000 0)" "slept 8h02m10s, S0ix 97%, used 1.90 Wh (236 mW average)"
has  "hibernate report has no average"       "$(report 1034 6 hibernate 39900000 0)" "hibernated 0h00m34s, used 0.10 Wh to save and restore"
has  "report on mains"                       "$(report 1034 6 suspend 39900000 1)" "on mains power"

finish
