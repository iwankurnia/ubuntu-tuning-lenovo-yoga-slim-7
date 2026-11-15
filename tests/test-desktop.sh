#!/usr/bin/env bash
# Desktop settings, fonts and the keyring: what is set on which kind of
# screen, that a second run changes nothing, and that your own later changes
# are respected.
set -u
. "$(dirname "$0")/helpers.sh"

GSDB=$W/gsettings.db

# desktop_env: stand-ins shared by the cases below.
desktop_env() {
    KIT_DIR=$KIT; STATE_DIR=$W/state; GS_BACKUP=$STATE_DIR/gsettings.before; GS_USER_FILE=$STATE_DIR/desktop-user
    FONT_CONF_NAME=45-yoga-slim7-fonts.conf; FONT_SMOOTH_CONF_NAME=46-yoga-slim7-oled-smoothing.conf
    WITH_FONTS=${WITH_FONTS:-1}; KEEP_DESKTOP=${KEEP_DESKTOP:-0}; HW_OLED=${HW_OLED:-1}; FONTS_READY=0
    DESK_USER=tester; DESK_UID=1000; DESK_HOME=$W/home
    mkdir -p "$W/home" "$W/state"; touch "$GSDB"
    find_desktop_user() { return 0; }
    getent() { echo "tester:x:1000:1000::$W/home:/bin/bash"; }
    sudo() { shift 2; "$@"; }
    as_user() { "$@"; }
    fc-cache() { :; }
    fc-list() { [ "${HAVE_CONSOLAS:-1}" = 1 ] && echo "/usr/share/fonts/CONSOLA.TTF: Consolas"; }
    gsettings() {
        local v
        case "$1" in
            get) v=$(grep -F "$2|$3|" "$GSDB" | tail -n 1 | cut -d'|' -f3-)
                 case "$3" in
                     gtk-theme) echo "${v:-'Yaru'}" ;;
                     color-scheme) echo "${v:-'default'}" ;;
                     *) echo "${v:-'unset'}" ;;
                 esac ;;
            set) [ "${GS_FAIL:-}" = "$3" ] && return 1
                 printf '%s|%s|%s\n' "$2" "$3" "$4" >> "$GSDB" ;;
        esac
    }
    eval "$(functions gs_set tune_desktop user_copy setup_fonts remove_fonts)"
}

run() { ( desktop_env; "$@" ) 2>&1 | sed "s|$W||g"; }
current() { grep -F "|$1|" "$GSDB" | tail -n 1 | cut -d'|' -f3-; }

# --- desktop options
out=$(HW_OLED=1 run tune_desktop)
has   "OLED: dark style set"                "$out" "ok    color-scheme = 'prefer-dark'"
has   "OLED: matching dark theme"           "$out" "gtk-theme = 'Yaru-dark'"
has   "idle options set"                    "$out" "idle-delay = uint32 180"
out=$(HW_OLED=1 run tune_desktop)
has   "second run changes nothing"          "$out" "skip  color-scheme (already 'prefer-dark')"
printf 'org.gnome.desktop.interface|color-scheme|%s\n' "'default'" >> "$GSDB"
out=$(HW_OLED=1 run tune_desktop)
has   "light style chosen later is respected" "$out" "color-scheme (you set it to 'default' after the first run; left alone)"
same  "light style still set"               "$(current color-scheme)" "'default'"
empty_work

out=$(HW_OLED=0 run tune_desktop)
has   "LCD: dark style not forced"          "$out" "skip  dark style (the screen is not an OLED panel"
lacks "LCD: colour scheme untouched"        "$out" "color-scheme ="
has   "LCD: idle options still set"         "$out" "idle-delay = uint32 180"
empty_work

out=$(KEEP_DESKTOP=1 run tune_desktop)
has   "--keep-desktop: nothing set"         "$out" "skip  left alone (--keep-desktop)"
empty_work

out=$(GS_FAIL=idle-delay run tune_desktop)
has   "a setting that fails is reported"    "$out" "WARN  could not set idle-delay"
out=$(run tune_desktop)
lacks "a failed setting is not blamed on you later" "$out" "idle-delay (you set it"
has   "a failed setting is tried again"     "$out" "ok    idle-delay = uint32 180"
empty_work

# --- fonts
out=$(WITH_FONTS=0 run setup_fonts)
has   "fonts are off by default"            "$out" "Ubuntu's own fonts left as they are"
same  "nothing installed"                   "$(find "$W/home" -type f | wc -l)" "0"

out=$(HW_OLED=1 run setup_fonts)
has   "OLED: fonts installed"               "$out" "ok    Selawik and the font rules installed"
has   "OLED: greyscale smoothing"           "$out" "font-antialiasing = 'grayscale'"
has   "Consolas used when installed"        "$out" "monospace-font-name = 'Consolas 12'"
same  "OLED: both rule files"               "$(ls "$W/home/.config/fontconfig/conf.d" | wc -l)" "2"
out=$(HW_OLED=1 run setup_fonts)
has   "second run changes nothing"          "$out" "skip  Selawik and the font rules (already in place)"

echo "<!-- mine -->" >> "$W/home/.config/fontconfig/conf.d/45-yoga-slim7-fonts.conf"
out=$(HW_OLED=1 run setup_fonts)
has   "an edited rules file is kept"        "$out" "your edited 45-yoga-slim7-fonts.conf was kept"

printf 'org.gnome.desktop.interface|font-antialiasing|%s\n' "'rgba'" >> "$GSDB"
rm "$W/home/.config/fontconfig/conf.d/46-yoga-slim7-oled-smoothing.conf"
out=$(HW_OLED=1 run setup_fonts)
has   "colour smoothing chosen later is respected" "$out" "font-antialiasing (you set it to 'rgba' after the first run; left alone)"
same  "its rules file is not put back"      "$(ls "$W/home/.config/fontconfig/conf.d" | grep -c oled-smoothing)" "0"
: > "$W/home/.config/fontconfig/conf.d/46-yoga-slim7-oled-smoothing.conf"

echo junk > "$W/home/.local/share/fonts/selawik/selawk.ttf"
run setup_fonts > /dev/null
same  "a damaged font file is repaired"     "$(cmp -s "$KIT/files/fonts/selawik/selawk.ttf" "$W/home/.local/share/fonts/selawik/selawk.ttf" && echo same)" "same"

out=$(run remove_fonts)
has   "undo removes the rules"              "$out" "ok    removed"
same  "undo removes both rule files"        "$(ls "$W/home/.config/fontconfig/conf.d" | wc -l)" "0"
same  "undo keeps the font files"           "$(ls "$W/home/.local/share/fonts/selawik" | wc -l)" "6"
empty_work

out=$(HW_OLED=0 HAVE_CONSOLAS=0 run setup_fonts)
has   "LCD: colour smoothing kept"          "$out" "skip  greyscale smoothing (the screen is not an OLED panel"
lacks "LCD: smoothing setting untouched"    "$out" "font-antialiasing ="
same  "LCD: one rule file"                  "$(ls "$W/home/.config/fontconfig/conf.d" | wc -l)" "1"
has   "no Consolas: code font left alone"   "$out" "code font left as it is: Consolas is not installed"
empty_work

finish
