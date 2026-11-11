#!/bin/bash
# Smoke test on a Mac with Claude Desktop installed (used by CI, see
# .github/workflows/mac.yml). Checks that ClaudeSwitch starts Claude with a separate
# --user-data-dir per profile, that picking a profile that already runs does not start a
# second copy, and takes screenshots of the picker into mac/build/.
# It replaces the ClaudeSwitch profiles and quits Claude: do not run it on your own Mac.
set -uo pipefail
cd "$(dirname "$0")"

APP="$PWD/build/ClaudeSwitch.app"
BIN="$APP/Contents/MacOS/ClaudeSwitch"
DOMAIN=io.github.oizopower.ClaudeSwitch
CLAUDE=/Applications/Claude.app
WORK_DIR="$HOME/ClaudeSwitch Test/work"   # with a space on purpose
failures=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

echo "Claude bundle id:  $(defaults read "$CLAUDE/Contents/Info" CFBundleIdentifier)"
echo "Claude version:    $(defaults read "$CLAUDE/Contents/Info" CFBundleShortVersionString)"
EXE="$CLAUDE/Contents/MacOS/$(defaults read "$CLAUDE/Contents/Info" CFBundleExecutable)"
echo "Claude executable: $EXE"

# Main Claude processes, one line per process: its arguments after the executable.
mains() { ps -axww -o args= | grep -F "$EXE" | grep -vF "Helper" | grep -v grep || true; }
count() { mains | grep -c . || true; }
quit_all() {
    pkill -f "$CLAUDE/Contents/MacOS/" 2>/dev/null
    pkill -x ClaudeSwitch 2>/dev/null
    sleep 3
}

set_profiles() {   # set_profiles name path name path ...
    local entries=()
    while [ $# -gt 0 ]; do
        entries+=("<dict><key>Name</key><string>$1</string><key>Path</key><string>$2</string></dict>")
        shift 2
    done
    defaults write $DOMAIN Profiles -array "${entries[@]}"
}

quit_all
rm -rf "$HOME/ClaudeSwitch Test"
defaults delete $DOMAIN 2>/dev/null
set_profiles "Personal" "" "Wörk" '$HOME/ClaudeSwitch Test/work/'

echo "--- launch 'work' (accent-insensitive match, \$HOME and trailing slash in the path)"
"$BIN" work || fail "exit code $?"
sleep 15
mains
if mains | grep -qF -- "--user-data-dir=$WORK_DIR"; then pass "Claude runs with the work folder"; else fail "no Claude with --user-data-dir=$WORK_DIR"; fi
if [ -n "$(ls -A "$WORK_DIR" 2>/dev/null)" ]; then pass "Claude writes into the work folder: $(ls "$WORK_DIR" | head -5 | tr '\n' ' ')"; else fail "work folder is empty"; fi

echo "--- launch 'Personal' (default profile) next to it"
"$BIN" Personal || fail "exit code $?"
sleep 10
mains
if [ "$(count)" = "2" ]; then pass "two Claude instances"; else fail "expected 2 Claude instances, got $(count)"; fi
if mains | grep -vqF -- "--user-data-dir"; then pass "one instance uses the default profile"; else fail "no instance without --user-data-dir"; fi

echo "--- launch both again: must not start extra copies"
"$BIN" work || fail "exit code $?"
"$BIN" personal || fail "exit code $?"
sleep 5
if [ "$(count)" = "2" ]; then pass "still two Claude instances"; else fail "expected 2 Claude instances, got $(count)"; fi
mains

echo "--- unknown profile (from a terminal: message on stderr, exit code 1)"
script -q /dev/null "$BIN" nobody; code=$?
if [ $code -ne 0 ]; then pass "unknown profile rejected"; else fail "unknown profile accepted"; fi
quit_all

echo "--- screenshots of the picker"
shoot() {   # shoot name
    open "$APP"
    sleep 4
    screencapture -x "build/$1.png" && echo "screenshot build/$1.png" || echo "screencapture failed for $1"
    pkill -x ClaudeSwitch
    sleep 1
}
shoot picker-2
set_profiles "Personal" "" "Work" "~/w" "Side project" "~/s" "Client" "~/c"
shoot picker-4
defaults write $DOMAIN Columns -int 4
set_profiles "Personal" "" "Work" "~/w" "Side project" "~/s" "Client" "~/c" "Test" "~/t"
shoot picker-5-wide
set_profiles "Personal" ""
shoot picker-1

# Mouse tests: need cliclick and accessibility rights, so they only warn when unavailable.
# The picker is centred horizontally on the 1024 pt wide runner screen.
if command -v cliclick >/dev/null; then
    echo "--- drag the right edge of the picker (3 columns -> 4)"
    defaults delete $DOMAIN Columns
    set_profiles "Personal" "" "Work" "~/w" "Side project" "~/s" "Client" "~/c" "Test" "~/t"
    open "$APP"; sleep 4
    screencapture -x build/drag-before.png
    right=$(( (1024 + 530) / 2 - 1 ))   # 3 columns = 530 pt content width
    cliclick -w 50 dd:$right,280 dm:$((right + 60)),280 dm:$((right + 120)),280 dm:$((right + 160)),280 du:$((right + 160)),280
    sleep 2
    screencapture -x build/drag-after.png
    echo "saved Columns: $(defaults read $DOMAIN Columns 2>/dev/null || echo none)"
    if [ "$(defaults read $DOMAIN Columns 2>/dev/null)" = "4" ]; then pass "dragging wider saves 4 columns"; else echo "WARN: dragging did not save 4 columns (no accessibility rights?)"; fi

    echo "--- open settings (link click)"
    link=$((right + 170 - 40))
    cliclick m:$((link - 5)),385 w:500 m:$link,389 w:500 c:$link,389; sleep 2
    screencapture -x build/settings-link.png
    cliclick kp:esc; sleep 1
    echo "--- open settings (Cmd+,)"
    cliclick kd:cmd t:, ku:cmd; sleep 2
    screencapture -x build/settings.png

    echo "--- add a profile through New…"
    cliclick m:700,205 w:500 m:704,210 w:500 c:704,210; sleep 2   # New… in the settings window
    screencapture -x build/new-profile.png
    cliclick t:"Nieuw profiel" kp:return; sleep 2
    screencapture -x build/settings-after-new.png
    defaults read $DOMAIN Profiles | tail -6
    if defaults read $DOMAIN Profiles | grep -q 'profiles/nieuw-profiel'; then pass "new profile stored with a suggested folder"; else echo "WARN: new profile not stored as expected"; fi
    pkill -x ClaudeSwitch
fi

defaults delete $DOMAIN
echo
if [ $failures -eq 0 ]; then echo "All checks passed"; else echo "$failures check(s) failed"; exit 1; fi
