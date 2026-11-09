#!/bin/bash
# Run regolith-sway-gtklock and regolith-sway-clamshell against stand-ins
# for trawlcat, the lock screens and the other programs they call, and check
# the arguments the lock screen gets. Run from the top of the source tree (debian/rules
# runs it at build time).
set -eu

SCRIPTS=$PWD/scripts
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
status=0

mkdir -p "$WORK/bin" "$WORK/home" "$WORK/my pictures" "$WORK/no-gtklock"
: > "$WORK/my pictures/lock screen.png"
: > "$WORK/home/lock.png"

# trawlcat <key> [default]: print the value from $STUB_RESOURCES
cat > "$WORK/bin/trawlcat" <<'STUB'
#!/bin/sh
value=$(sed -n "s/^$1:[[:space:]]*//p" "$STUB_RESOURCES" | tail -n 1)
if [ -n "$value" ]; then printf '%s\n' "$value"; elif [ "$#" -ge 2 ]; then printf '%s\n' "$2"; else exit 1; fi
STUB

# gtklock: log each argument on its own line, then a separator
cat > "$WORK/bin/gtklock" <<'STUB'
#!/bin/sh
for arg in "$@"; do printf '[%s]\n' "$arg"; done >> "$STUB_LOG"
echo -- >> "$STUB_LOG"
STUB
# swaylock, another lock application: the same, after its name
cat > "$WORK/bin/swaylock" <<'STUB'
#!/bin/sh
echo swaylock >> "$STUB_LOG"
for arg in "$@"; do printf '[%s]\n' "$arg"; done >> "$STUB_LOG"
echo -- >> "$STUB_LOG"
STUB

# The lid close script also asks sway, logind and the power supply. sway's
# outputs are $STUB_OUTPUTS (a laptop panel alone by default); other
# commands are logged.
cat > "$WORK/bin/swaymsg" <<'STUB'
#!/bin/sh
if [ "$1" = -t ] && [ "$2" = get_outputs ]; then
    echo "${STUB_OUTPUTS:-[{\"name\":\"eDP-1\"}]}"
    exit 0
fi
echo "[swaymsg $*]" >> "$STUB_LOG"
STUB
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/busctl"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/on_ac_power"
# shellcheck disable=SC2016 # expanded by the stand-in, not here
printf '#!/bin/sh\necho "[systemctl $*]" >> "$STUB_LOG"\n' > "$WORK/bin/systemctl"
chmod +x "$WORK/bin/"*

export STUB_RESOURCES=$WORK/resources STUB_LOG=$WORK/log HOME=$WORK/home
unset XDG_CONFIG_HOME
# The lid close script without regolith-sway-gtklock (the package isn't
# installed)
ln -s "$SCRIPTS/regolith-sway-clamshell" "$WORK/no-gtklock/"
export PATH="$SCRIPTS:$WORK/bin:$PATH"

# run <command> <resources...>: run the command with these resources
run() {
    local cmd=$1; shift
    printf '%s\n' "$@" > "$STUB_RESOURCES"
    : > "$STUB_LOG"
    sh -c "$cmd" > /dev/null 2> "$WORK/err" || echo "exit status $?" >> "$WORK/err"
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

# expect_warning <description> <text>: a warning with this text was printed
expect_warning() {
    if grep -qF -- "$2" "$WORK/err"; then
        echo "ok   $1"
    else
        echo "FAIL $1: no '$2' on stderr:" >&2
        sed 's/^/       /' "$WORK/err" >&2
        status=1
    fi
}

SPACE="$WORK/my pictures/lock screen.png"

# The lock key: the default of wm.program.lock_sway
run regolith-sway-gtklock "regolith.lockscreen.wallpaper.file: $SPACE"
expect 'path with spaces: one argument' '[--background]' "[$SPACE]" --
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.file: ~/lock.png'
expect 'path under ~: expanded' '[--background]' "[$WORK/home/lock.png]" --
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.file: /nonexistent/lock.png'
expect 'missing file: locks without an image' --
expect_warning 'missing file: warning' "no such file: '/nonexistent/lock.png'"
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.file: ~/missing.png'
expect 'missing file under ~: locks without an image' --
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.file:'
expect 'no wallpaper: locks without an image' --
run 'regolith-sway-gtklock -d' "regolith.lockscreen.wallpaper.file: $SPACE"
expect 'arguments go to gtklock' '[-d]' '[--background]' "[$SPACE]" --

# The look's gtklock stylesheet, unless the user has one of their own
: > "$WORK/my pictures/look style.css"
STYLE="$WORK/my pictures/look style.css"
run regolith-sway-gtklock "gtklock.stylesheet: $STYLE" "regolith.lockscreen.wallpaper.file: $SPACE"
expect 'look stylesheet' '[--style]' "[$STYLE]" '[--background]' "[$SPACE]" --
run 'regolith-sway-gtklock -d' "gtklock.stylesheet: $STYLE"
expect 'look stylesheet, arguments' '[-d]' '[--style]' "[$STYLE]" --
run regolith-sway-gtklock 'gtklock.stylesheet: /nonexistent/style.css'
expect 'missing stylesheet: locks without it' --
expect_warning 'missing stylesheet: warning' "no such file: '/nonexistent/style.css'"
mkdir -p "$WORK/home/.config/gtklock"
printf '[main]\nstyle = /tmp/mine.css\n' > "$WORK/home/.config/gtklock/config.ini"
run regolith-sway-gtklock "gtklock.stylesheet: $STYLE"
expect "user's config.ini style: look stylesheet not used" --
rm "$WORK/home/.config/gtklock/config.ini"
: > "$WORK/home/.config/gtklock/style.css"
run regolith-sway-gtklock "gtklock.stylesheet: $STYLE"
expect "user's style.css: look stylesheet not used" --
rm -r "$WORK/home/.config/gtklock"

# Lid close, one display, on AC: lock, and lock before suspending
run 'regolith-sway-clamshell LID_CLOSE' 'wm.lidclose.action.power: LOCK' \
    "regolith.lockscreen.wallpaper.file: $SPACE"
expect 'lid close, LOCK: path with spaces' '[--background]' "[$SPACE]" --
run 'regolith-sway-clamshell LID_CLOSE' 'wm.lidclose.action.power: LOCK' \
    'regolith.lockscreen.wallpaper.file: ~/lock.png'
expect 'lid close, LOCK: path under ~' '[--background]' "[$WORK/home/lock.png]" --
run 'regolith-sway-clamshell LID_CLOSE' 'wm.lidclose.action.power: LOCK' \
    'regolith.lockscreen.wallpaper.file: /nonexistent/lock.png'
expect 'lid close, LOCK: missing file' --
run 'regolith-sway-clamshell LID_CLOSE' 'wm.lidclose.action.power: SLEEP' \
    "regolith.lockscreen.wallpaper.file: $SPACE"
expect 'lid close, SLEEP: locks first' '[-d]' '[--background]' "[$SPACE]" -- '[systemctl suspend]'

# wm.program.lock_sway still replaces the default
run 'regolith-sway-clamshell LID_CLOSE' 'wm.lidclose.action.power: LOCK' \
    'wm.program.lock_sway: gtklock --idle-hide' "regolith.lockscreen.wallpaper.file: $SPACE"
expect 'lid close: wm.program.lock_sway' '[--idle-hide]' --
run 'regolith-sway-clamshell LID_CLOSE' 'wm.lidclose.action.power: SLEEP' \
    'wm.program.lock_sway: swaylock -f' "regolith.lockscreen.wallpaper.file: $SPACE"
expect 'lid close, SLEEP: wm.program.lock_sway, another locker' swaylock '[-f]' -- '[systemctl suspend]'

# Without regolith-sway-gtklock, another locker set in wm.program.lock_sway
# still locks, and with none the lid close still suspends
run "PATH=$WORK/no-gtklock:$WORK/bin:/usr/bin:/bin regolith-sway-clamshell LID_CLOSE" \
    'wm.lidclose.action.power: LOCK' 'wm.program.lock_sway: swaylock -f'
expect 'no regolith-sway-gtklock, LOCK: wm.program.lock_sway' swaylock '[-f]' --
run "PATH=$WORK/no-gtklock:$WORK/bin:/usr/bin:/bin regolith-sway-clamshell LID_CLOSE" \
    'wm.lidclose.action.power: SLEEP' 'wm.program.lock_sway: swaylock -f'
expect 'no regolith-sway-gtklock, SLEEP: wm.program.lock_sway' swaylock '[-f]' -- '[systemctl suspend]'
run "PATH=$WORK/no-gtklock:$WORK/bin:/usr/bin:/bin regolith-sway-clamshell LID_CLOSE" \
    'wm.lidclose.action.power: SLEEP'
expect 'no regolith-sway-gtklock, no locker set, SLEEP: still suspends' '[systemctl suspend]'

# Lid close with an external monitor: the laptop panel is turned off, whether
# it is an eDP, LVDS or DSI output
for panel in eDP-1 LVDS-1 DSI-1; do
    export STUB_OUTPUTS="[{\"name\":\"HDMI-A-1\"},{\"name\":\"$panel\"}]"
    run 'regolith-sway-clamshell LID_CLOSE' 'wm.lidclose.action.power: SLEEP'
    expect "clamshell, $panel: panel turned off" "[swaymsg output $panel disable]"
    run 'regolith-sway-clamshell LID_OPEN'
    expect "clamshell, $panel: panel turned on" "[swaymsg output $panel enable]"
done
# Two monitors and no laptop panel: the lid close action runs
export STUB_OUTPUTS='[{"name":"Virtual-1"},{"name":"HDMI-A-1"}]'
run 'regolith-sway-clamshell LID_CLOSE' 'wm.lidclose.action.power: SLEEP'
expect 'two monitors, no panel, SLEEP: locks and suspends' '[-d]' -- '[systemctl suspend]'
run 'regolith-sway-clamshell LID_CLOSE' 'wm.lidclose.action.power: LOCK'
expect 'two monitors, no panel, LOCK: locks' --
run 'regolith-sway-clamshell LID_OPEN'
expect 'two monitors, no panel: lid open changes nothing'
# ... unless wm.clamshell.display names the panel
run 'regolith-sway-clamshell LID_CLOSE' 'wm.lidclose.action.power: SLEEP' 'wm.clamshell.display: Virtual-1'
expect 'wm.clamshell.display: that output turned off' '[swaymsg output Virtual-1 disable]'
unset STUB_OUTPUTS

exit $status
