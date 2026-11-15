#!/usr/bin/env bash
# Runs every test. Needs no sudo and changes nothing on the system:
#
#     bash tests/run.sh
#
# The tests cover the installer's decisions on made-up hardware. They cannot
# show that a setting works on a real laptop; only running the installer on
# that laptop does.
set -u
cd "$(dirname "$0")/.." || exit 1
failed=0

for f in install.sh files/yoga-power; do
    bash -n "$f" || { echo "syntax error in $f"; failed=1; }
done
sh -n files/yoga-sleep-report || { echo "syntax error in files/yoga-sleep-report"; failed=1; }
python3 -m py_compile files/yoga-scale || failed=1
python3 -m py_compile files/nautilus/open-with-vscode.py || failed=1
find files -name __pycache__ -prune -exec rm -r {} + 2>/dev/null
for f in install.sh files/yoga-power files/yoga-sleep-report files/yoga-scale files/nautilus/open-with-vscode.py; do
    if [ "$(tr -cd '\r' < "$f" | wc -c)" -ne 0 ]; then
        echo "$f has Windows line endings"
        failed=1
    fi
done
[ "$failed" -eq 0 ] && echo "syntax and line endings: ok"

for t in tests/test-*.sh; do
    bash "$t" || failed=1
done

if [ "$failed" -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "SOME TESTS FAILED"
fi
exit "$failed"
