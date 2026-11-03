#!/bin/bash
# Run regolith-i3-screenshot against stand-ins for gdbus (gnome-flashback's
# screenshot service), slop, xclip and notify-send, and check the calls it
# makes. Also check that i3's 80_screenshot binds the three keys of sway's
# 80_grimshot that gnome-flashback doesn't cover, with the same resources and
# viewer labels. Run from the top of the source tree (debian/rules runs it at
# build time).
set -eu

SCRIPTS=$PWD/scripts
I3_PARTIAL=$PWD/usr/share/regolith/i3/config.d/80_screenshot
SWAY_PARTIAL=$PWD/usr/share/regolith/sway/config.d/80_grimshot
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
status=0

mkdir -p "$WORK/bin"

# gdbus: log the call; answer like gnome-flashback (a file in $STUB_DIR named
# after the last argument, or nothing for the clipboard)
cat > "$WORK/bin/gdbus" <<'STUB'
#!/bin/sh
echo "[gdbus $*]" >> "$STUB_LOG"
[ -n "${STUB_GDBUS_FAIL-}" ] && { echo "Error: no such name" >&2; exit 1; }
for last in "$@"; do :; done
if [ -z "$last" ]; then echo "(true, '')"; else printf "(true, '%s/%s.png')\n" "$STUB_DIR" "$last"; fi
STUB
# slop: print $STUB_SLOP, or fail as when the selection is cancelled
cat > "$WORK/bin/slop" <<'STUB'
#!/bin/sh
echo "[slop $*]" >> "$STUB_LOG"
[ -n "$STUB_SLOP" ] || exit 1
echo "$STUB_SLOP"
STUB
cat > "$WORK/bin/xclip" <<'STUB'
#!/bin/sh
echo "[xclip $*]" >> "$STUB_LOG"
STUB
cat > "$WORK/bin/notify-send" <<'STUB'
#!/bin/sh
echo "[notify-send $*]" >> "$STUB_LOG"
STUB
# date: a fixed time
printf '#!/bin/sh\necho "2026-11-03 10-20-30"\n' > "$WORK/bin/date"
chmod +x "$WORK/bin/"*

export STUB_LOG=$WORK/log STUB_DIR="$WORK/my pictures" STUB_SLOP='' LANGUAGE=C
export PATH="$SCRIPTS:$WORK/bin:$PATH"

# run <args...>: run the helper; the exit status goes to the log
run() {
    : > "$STUB_LOG"
    local rc=0
    regolith-i3-screenshot "$@" > "$WORK/out" 2> "$WORK/err" || rc=$?
    echo "exit $rc" >> "$STUB_LOG"
}

# expect <description> <line>...: the log is exactly these lines
expect() {
    local desc=$1; shift
    if [ "$(cat "$STUB_LOG")" = "$(printf '%s\n' "$@")" ]; then
        echo "ok   $desc"
    else
        echo "FAIL $desc: expected:" >&2
        printf '       %s\n' "$@" >&2
        echo "     got:" >&2
        sed 's/^/       /' "$STUB_LOG" >&2
        status=1
    fi
}

DBUS="gdbus call --session --dest org.gnome.Shell.Screenshot --object-path /org/gnome/Shell/Screenshot --method org.gnome.Shell.Screenshot"
NAME="Screenshot from 2026-11-03 10-20-30"
FILE="$STUB_DIR/$NAME.png"

run copy active
expect 'copy active: the window, to the clipboard, no notification' \
    "[$DBUS.ScreenshotWindow true false true ]" 'exit 0'

run --notify save screen
expect 'save screen: all screens, to a file, notified' \
    "[$DBUS.Screenshot false true $NAME]" \
    "[notify-send -t 3000 -a Screenshot -i $FILE Screenshot of screen $NAME.png]" 'exit 0'
if [ "$(cat "$WORK/out")" = "$FILE" ]; then echo "ok   save screen: prints the file"
else echo "FAIL save screen: printed '$(cat "$WORK/out")'" >&2; status=1; fi

STUB_SLOP="12 34 560 780" run --notify savecopy anything
expect 'savecopy anything: the selection, saved, copied, notified' \
    "[slop -f %x %y %w %h]" \
    "[$DBUS.ScreenshotArea 12 34 560 780 true $NAME]" \
    "[xclip -selection clipboard -t image/png -i $FILE]" \
    "[notify-send -t 3000 -a Screenshot -i $FILE Screenshot of anything $NAME.png and clipboard]" 'exit 0'

STUB_SLOP='' run --notify savecopy anything
expect 'savecopy anything, cancelled: nothing taken' "[slop -f %x %y %w %h]" 'exit 1'

STUB_GDBUS_FAIL=1 run --notify save screen
expect 'no screenshot service: an error notification' \
    "[$DBUS.Screenshot false true $NAME]" \
    "[notify-send -t 3000 -a Screenshot -u critical Screenshot Error: gnome-flashback's screenshot service failed: Error: no such name]" 'exit 2'

STUB_GDBUS_FAIL=1 run copy active
expect 'no screenshot service, no --notify: no notification' \
    "[$DBUS.ScreenshotWindow true false true ]" 'exit 2'

run save area
expect 'unknown subject: usage' 'exit 64'

# A file name that the service escapes (a quote and a backslash in the folder)
cat > "$WORK/bin/gdbus" <<'STUB'
#!/bin/sh
printf '%s\n' "(true, '/pictures/it\\'s \\\\ here/x.png')"
STUB
run save screen
if [ "$(cat "$WORK/out")" = "/pictures/it's \\ here/x.png" ]; then echo "ok   escaped file name: unescaped"
else echo "FAIL escaped file name: printed '$(cat "$WORK/out")'" >&2; status=1; fi

# bindings <partial>: "<resource default line> | <command>" for each of the
# three $mod+Print keys, with the viewer label
bindings() {
    awk '/^## /{label=$0} $1 == "set_from_resource" {res=$2" "$3" "$4}
        $1 == "bindsym" && $2 ~ /^\$mod\+/ {print label " | " res " | " $2}' "$1"
}
if [ "$(bindings "$I3_PARTIAL")" = "$(bindings "$SWAY_PARTIAL")" ] &&
    [ "$(bindings "$I3_PARTIAL" | wc -l)" -eq 3 ]; then
    echo "ok   i3 has sway's three \$mod+Print keys, labels and resources"
else
    echo "FAIL i3 and sway \$mod+Print keys differ:" >&2
    diff <(bindings "$SWAY_PARTIAL") <(bindings "$I3_PARTIAL") >&2 || true
    status=1
fi
# Each i3 key runs the helper with the arguments sway gives grimshot
cmds() {
    awk '$1 == "bindsym" && $2 ~ /^\$mod\+/ {
        c = ""; for (i = 3; i <= NF; i++) c = c " " $i
        sub(/^ exec (--no-startup-id )?/, "", c); sub(/^(grimshot|regolith-i3-screenshot) /, "", c); print c }' "$1"
}
if [ "$(cmds "$I3_PARTIAL")" = "$(cmds "$SWAY_PARTIAL")" ]; then
    echo "ok   i3 keys take the same actions as grimshot's"
else
    echo "FAIL i3 key actions differ from sway's:" >&2
    diff <(cmds "$SWAY_PARTIAL") <(cmds "$I3_PARTIAL") >&2 || true
    status=1
fi

exit $status
