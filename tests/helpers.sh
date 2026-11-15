# Shared by the test scripts. Source it; do not run it.
#
# The tests never touch the real system: every script works in a throwaway
# folder, and apt, dpkg, systemctl, swapon and the like are replaced by
# stand-ins. They check the installer's decisions, not the hardware.

KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
W=$(mktemp -d)
PASSED=0
FAILED=0

cleanup() {
    [ -n "${W:-}" ] && [ -d "$W" ] || return 0
    find "$W" -depth -mindepth 1 -delete 2>/dev/null
    rmdir "$W" 2>/dev/null
}
trap cleanup EXIT

# empty_work: clears the work folder between cases.
empty_work() { find "$W" -depth -mindepth 1 -delete 2>/dev/null; }

# has NAME TEXT PATTERN: passes when TEXT contains the fixed string PATTERN.
has() {
    if printf '%s' "$2" | grep -qF -- "$3"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL  %s\n      expected to find: %s\n' "$1" "$3"
        printf '%s\n' "$2" | sed 's/^/      | /' | head -n 25
    fi
}

# lacks NAME TEXT PATTERN: passes when TEXT does not contain PATTERN.
lacks() {
    if printf '%s' "$2" | grep -qF -- "$3"; then
        FAILED=$((FAILED + 1))
        printf 'FAIL  %s\n      did not expect: %s\n' "$1" "$3"
        printf '%s\n' "$2" | sed 's/^/      | /' | head -n 25
    else
        PASSED=$((PASSED + 1))
    fi
}

# same NAME ACTUAL EXPECTED
same() {
    if [ "$2" = "$3" ]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL  %s\n      expected: %s\n      got:      %s\n' "$1" "$3" "$2"
    fi
}

# functions NAME...: prints the named functions from install.sh, for eval.
functions() {
    local f
    for f in "$@"; do
        sed -n "/^$f() {/,/^}/p" "$KIT/install.sh"
        grep -E "^$f\(\) \{.*\}\$" "$KIT/install.sh"       # one-line functions
    done
}

# The installer's own messages, so output reads like a real run.
say()  { printf '== %s\n' "$*"; }
ok()   { printf '   ok    %s\n' "$*"; }
skip() { printf '   skip  %s\n' "$*"; }
warn() { printf '   WARN  %s\n' "$*"; }
die()  { printf '   STOP  %s\n' "$*"; exit 1; }

finish() {
    printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$PASSED" "$FAILED"
    [ "$FAILED" -eq 0 ]
}
