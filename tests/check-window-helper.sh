#!/bin/bash
# Check how regolith-window-helper finds desktop files, splits their Exec
# lines and reads its settings, against desktop files in a scratch data
# directory. Run from the top of the source tree (debian/rules runs it at
# build time).
set -eu

SCRIPT=$PWD/scripts/regolith-window-helper
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/home/applications" "$WORK/sys1/applications/org" \
    "$WORK/sys2/applications"

# desktop <file> <name> <exec> [extra lines...]
desktop() {
    local file=$1
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n' "$2" "$3" > "$file"
    shift 3
    for line in "$@"; do printf '%s\n' "$line" >> "$file"; done
}

desktop "$WORK/sys1/applications/org.example.Notes.desktop" Notes \
    'notes --system %U' 'StartupWMClass=SystemNotes'
desktop "$WORK/home/applications/org.example.Notes.desktop" Notes \
    'notes --user %U' 'StartupWMClass=UserNotes'
desktop "$WORK/sys1/applications/org/example-Sub.desktop" Sub 'sub'
desktop "$WORK/sys1/applications/org.example.Gone.desktop" Gone 'gone'
desktop "$WORK/home/applications/org.example.Gone.desktop" Gone 'gone' 'Hidden=true'
desktop "$WORK/sys1/applications/org.example.First.desktop" First 'first'
desktop "$WORK/sys2/applications/org.example.First.desktop" First 'second'
desktop "$WORK/sys2/applications/org.example.Second.desktop" Second 'second'

XDG_DATA_HOME=$WORK/home XDG_DATA_DIRS=$WORK/sys1:$WORK/sys2 \
python3 -B - "$SCRIPT" <<'EOF'
import importlib.machinery
import importlib.util
import sys

loader = importlib.machinery.SourceFileLoader("helper", sys.argv[1])
spec = importlib.util.spec_from_loader("helper", loader)
helper = importlib.util.module_from_spec(spec)
loader.exec_module(helper)
status = 0


def check(label, got, expected):
    global status
    if got == expected:
        print(f"ok   {label}")
    else:
        print(f"FAIL {label}: got {got!r}, expected {expected!r}", file=sys.stderr)
        status = 1


def entry(desktop_id, key="Exec"):
    found = helper.lookup_desktop(desktop_id)
    return None if found is None else found.get(key)


check("user file first", entry("org.example.Notes"), "notes --user %U")
check("user StartupWMClass", entry("org.example.Notes", "StartupWMClass"), "UserNotes")
check("optional .desktop suffix", entry("org.example.Notes.desktop"), "notes --user %U")
check("subdirectory id", entry("org-example-Sub"), "sub")
check("hidden user file hides the application", entry("org.example.Gone"), None)
check("data directories in order", entry("org.example.First"), "first")
check("second data directory", entry("org.example.Second"), "second")
check("unknown id", entry("org.example.Unknown"), None)

check("field codes removed", helper.exec_argv("app %f %F %u %U %i %c %k --x"),
      ["app", "--x"])
check("quoted arguments", helper.exec_argv(r'"/opt/my app/run" "two words" "a\"b"'),
      ["/opt/my app/run", "two words", 'a"b'])
check("escaped characters", helper.exec_argv(r'run "\$HOME" "\`x\`" "a\\b"'),
      ["run", "$HOME", "`x`", "a\\b"])
check("percent signs", helper.exec_argv('run "50%%" 100%%'), ["run", "50%", "100%"])
check("empty quoted argument", helper.exec_argv('run ""'), ["run", ""])
check("key file escapes", helper.unescape_value(r"a\sb\\c"), "a b\\c")

check("opacity setting", helper.opacity_setting("0.6"), 0.6)
for bad in ("0.09", "0", "-1", "1.5", "abc", "nan", "inf", ""):
    check(f"opacity setting {bad!r}", helper.opacity_setting(bad), 0.85)
check("pop-out size", helper.percent("40", 60), 40)
for bad in ("0", "101", "-5", "wide", ""):
    check(f"pop-out size {bad!r}", helper.percent(bad, 60), 60)

sys.exit(status)
EOF
