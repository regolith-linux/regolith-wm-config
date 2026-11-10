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

# gtklock: log each argument on its own line, then a separator, and copy
# the stylesheet it gets to $STUB_LOG.css
cat > "$WORK/bin/gtklock" <<'STUB'
#!/bin/sh
for arg in "$@"; do printf '[%s]\n' "$arg"; done >> "$STUB_LOG"
echo -- >> "$STUB_LOG"
while [ "$#" -ge 2 ]; do
    if [ "$1" = --style ]; then cat "$2" > "$STUB_LOG.css"; fi
    shift
done
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

# A few lines in the format of /usr/share/X11/rgb.txt
cat > "$WORK/rgb.txt" <<'EOF'
! $Xorg: rgb.txt,v 1.3 2000/08/17 19:54:00 cpqbld Exp $
 70 130 180		steel blue
 70 130 180		SteelBlue
EOF

mkdir -p "$WORK/run"
export STUB_RESOURCES=$WORK/resources STUB_LOG=$WORK/log HOME=$WORK/home
export REGOLITH_RGB_TXT=$WORK/rgb.txt XDG_RUNTIME_DIR=$WORK/run
unset XDG_CONFIG_HOME
# The stylesheet regolith-sway-gtklock writes for gtklock
CSS=$WORK/run/regolith-sway-gtklock.css
# The lid close script without regolith-sway-gtklock (the package isn't
# installed)
ln -s "$SCRIPTS/regolith-sway-clamshell" "$WORK/no-gtklock/"
export PATH="$SCRIPTS:$WORK/bin:$PATH"

# run <command> <resources...>: run the command with these resources
run() {
    local cmd=$1; shift
    printf '%s\n' "$@" > "$STUB_RESOURCES"
    : > "$STUB_LOG"
    rm -f "$STUB_LOG.css" "$CSS"
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

# expect_css <description> <line>...: gtklock got a stylesheet of exactly
# these lines
expect_css() {
    local desc=$1; shift
    if [ -f "$STUB_LOG.css" ] && [ "$(cat "$STUB_LOG.css")" = "$(printf '%s\n' "$@")" ]; then
        echo "ok   $desc"
    else
        echo "FAIL $desc: expected the stylesheet:" >&2
        printf '       %s\n' "$@" >&2
        echo "     got:" >&2
        sed 's/^/       /' "$STUB_LOG.css" >&2 2> /dev/null || echo "       (none)" >&2
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

# The lock key: the default of wm.program.lock_sway. gtklock gets the image
# with --background, and its placement in the stylesheet (zoom when unset).
ZOOM=('window {' '  background-size: cover;' '  background-repeat: no-repeat;' '  background-position: center;' '}')
# The panel behind the clock and the password prompt, after the background
PANEL=('#window-box {' '  background-color: @theme_bg_color;' '  border-radius: 10px;' '  padding: 24px 36px;' '}')
run regolith-sway-gtklock "regolith.lockscreen.wallpaper.file: $SPACE"
expect 'path with spaces: one argument' '[--style]' "[$CSS]" '[--background]' "[$SPACE]" --
expect_css 'image: zoomed by default' "${ZOOM[@]}" "${PANEL[@]}"
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.file: ~/lock.png'
expect 'path under ~: expanded' '[--style]' "[$CSS]" '[--background]' "[$WORK/home/lock.png]" --
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.file: /nonexistent/lock.png'
expect 'missing file: locks without an image' --
expect_warning 'missing file: warning' "no such file: '/nonexistent/lock.png'"
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.file: ~/missing.png'
expect 'missing file under ~: locks without an image' --
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.file:'
expect 'no wallpaper: locks without an image' --
run 'regolith-sway-gtklock -d' "regolith.lockscreen.wallpaper.file: $SPACE"
expect 'arguments go to gtklock' '[-d]' '[--style]' "[$CSS]" '[--background]' "[$SPACE]" --

# regolith.lockscreen.wallpaper.options: GNOME's picture-options
for case in 'wallpaper:auto:repeat:left top' 'centered:auto:no-repeat:center' \
            'scaled:contain:no-repeat:center' 'stretched:100% 100%:no-repeat:center' \
            'zoom:cover:no-repeat:center' 'spanned:cover:no-repeat:center'; do
    IFS=: read -r option size repeat position <<< "$case"
    run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.file: ~/lock.png' \
        "regolith.lockscreen.wallpaper.options: $option"
    expect_css "options $option" 'window {' "  background-size: $size;" \
        "  background-repeat: $repeat;" "  background-position: $position;" '}' "${PANEL[@]}"
done
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.file: ~/lock.png' \
    'regolith.lockscreen.wallpaper.options: none' 'regolith.lockscreen.wallpaper.color.primary: #323A4C'
expect 'options none: no image' '[--style]' "[$CSS]" --
expect_css 'options none: the colour' 'window {' '  background-color: #323a4c;' \
    '  background-image: none;' '}' "${PANEL[@]}"
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.file: ~/lock.png' \
    'regolith.lockscreen.wallpaper.options: centered' 'regolith.lockscreen.wallpaper.color.primary: #323A4C'
expect_css 'image and colour: the colour around it' 'window {' '  background-color: #323a4c;' \
    '  background-size: auto;' '  background-repeat: no-repeat;' '  background-position: center;' '}' "${PANEL[@]}"

# The colours, when there is no image
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.color.primary: #323A4C'
expect "the default look's colour" '[--style]' "[$CSS]" --
expect_css "the default look's colour: drawn" 'window {' '  background-color: #323a4c;' \
    '  background-image: none;' '}' "${PANEL[@]}"
for case in '#abc:#aabbcc' '#000011112222:#001122' 'rgb(255, 0, 50%):#ff0080' \
            'Steel Blue:#4682b4'; do
    color=${case%:*} hex=${case##*:}
    run regolith-sway-gtklock "regolith.lockscreen.wallpaper.color.primary: $color"
    expect_css "colour $color" 'window {' "  background-color: $hex;" '  background-image: none;' '}' "${PANEL[@]}"
done
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.color.primary: #000044' \
    'regolith.lockscreen.wallpaper.color.secondary: #4040ff' \
    'regolith.lockscreen.wallpaper.color.shading.type: vertical'
expect_css 'vertical gradient' 'window {' '  background-color: #000044;' \
    '  background-image: linear-gradient(to bottom, #000044, #4040ff);' '}' "${PANEL[@]}"
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.color.primary: #000044' \
    'regolith.lockscreen.wallpaper.color.secondary: rgb(64, 64, 255)' \
    'regolith.lockscreen.wallpaper.color.shading.type: horizontal'
expect_css 'horizontal gradient' 'window {' '  background-color: #000044;' \
    '  background-image: linear-gradient(to right, #000044, #4040ff);' '}' "${PANEL[@]}"
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.color.primary: #000044' \
    'regolith.lockscreen.wallpaper.color.secondary: #4040ff' \
    'regolith.lockscreen.wallpaper.color.shading.type: solid'
expect_css 'solid shading: the primary colour' 'window {' '  background-color: #000044;' \
    '  background-image: none;' '}' "${PANEL[@]}"
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.color.primary: #000044' \
    'regolith.lockscreen.wallpaper.color.secondary: no-such-colour' \
    'regolith.lockscreen.wallpaper.color.shading.type: vertical'
expect_css 'bad secondary colour: the primary colour' 'window {' '  background-color: #000044;' \
    '  background-image: none;' '}' "${PANEL[@]}"
expect_warning 'bad secondary colour: warning' "not a colour: 'no-such-colour'"
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.color.primary: #12345'
expect 'bad colour: locks without it' --
expect_warning 'bad colour: warning' "not a colour: '#12345'"
run regolith-sway-gtklock 'regolith.lockscreen.wallpaper.file: /nonexistent/lock.png' \
    'regolith.lockscreen.wallpaper.color.primary: #323A4C'
expect 'missing file: the colour instead' '[--style]' "[$CSS]" --

# The look's gtklock stylesheet, imported after the background so that its
# rules win, unless the user has one of their own
: > "$WORK/my pictures/look style.css"
STYLE="$WORK/my pictures/look style.css"
run regolith-sway-gtklock "gtklock.stylesheet: $STYLE" "regolith.lockscreen.wallpaper.file: $SPACE"
expect 'look stylesheet' '[--style]' "[$CSS]" '[--background]' "[$SPACE]" --
expect_css 'look stylesheet: imported after the image placement' "${ZOOM[@]}" "${PANEL[@]}" "@import url(\"$STYLE\");"
run regolith-sway-gtklock "gtklock.stylesheet: $STYLE" 'regolith.lockscreen.wallpaper.color.primary: #323A4C'
expect_css 'look stylesheet: imported after the colour' 'window {' '  background-color: #323a4c;' \
    '  background-image: none;' '}' "${PANEL[@]}" "@import url(\"$STYLE\");"
: > "$WORK/my pictures/say \"cheese\" \\ style.css"
run regolith-sway-gtklock "gtklock.stylesheet: $WORK/my pictures/say \"cheese\" \\ style.css" \
    'regolith.lockscreen.wallpaper.color.primary: #323A4C'
expect_css 'look stylesheet: quotes and backslashes escaped' 'window {' '  background-color: #323a4c;' \
    '  background-image: none;' '}' "${PANEL[@]}" "@import url(\"$WORK/my pictures/say \\\"cheese\\\" \\\\ style.css\");"
run 'regolith-sway-gtklock -d' "gtklock.stylesheet: $STYLE"
expect 'look stylesheet alone: passed as it is' '[-d]' '[--style]' "[$STYLE]" --
run regolith-sway-gtklock 'gtklock.stylesheet: /nonexistent/style.css'
expect 'missing stylesheet: locks without it' --
expect_warning 'missing stylesheet: warning' "no such file: '/nonexistent/style.css'"
mkdir -p "$WORK/home/.config/gtklock"
printf '[main]\nstyle = /tmp/mine.css\n' > "$WORK/home/.config/gtklock/config.ini"
run regolith-sway-gtklock "gtklock.stylesheet: $STYLE" 'regolith.lockscreen.wallpaper.color.primary: #323A4C'
expect "user's config.ini style: look stylesheet and colours not used" --
rm "$WORK/home/.config/gtklock/config.ini"
: > "$WORK/home/.config/gtklock/style.css"
run regolith-sway-gtklock "gtklock.stylesheet: $STYLE" 'regolith.lockscreen.wallpaper.color.primary: #323A4C'
expect "user's style.css: look stylesheet and colours not used" --
run regolith-sway-gtklock "gtklock.stylesheet: $STYLE" "regolith.lockscreen.wallpaper.file: $SPACE"
expect "user's style.css: the image still shown" '[--background]' "[$SPACE]" --
rm -r "$WORK/home/.config/gtklock"

# The stylesheet can't be written: the session still locks, with the look's
# stylesheet and the image
run "XDG_RUNTIME_DIR=$WORK/nonexistent regolith-sway-gtklock" "gtklock.stylesheet: $STYLE" \
    "regolith.lockscreen.wallpaper.file: $SPACE"
expect "stylesheet not written: look stylesheet and image" '[--style]' "[$STYLE]" '[--background]' "[$SPACE]" --
expect_warning "stylesheet not written: warning" "can't write the stylesheet"

# Lid close, one display, on AC: lock, and lock before suspending
run 'regolith-sway-clamshell LID_CLOSE' 'wm.lidclose.action.power: LOCK' \
    "regolith.lockscreen.wallpaper.file: $SPACE"
expect 'lid close, LOCK: path with spaces' '[--style]' "[$CSS]" '[--background]' "[$SPACE]" --
run 'regolith-sway-clamshell LID_CLOSE' 'wm.lidclose.action.power: LOCK' \
    'regolith.lockscreen.wallpaper.file: ~/lock.png'
expect 'lid close, LOCK: path under ~' '[--style]' "[$CSS]" '[--background]' "[$WORK/home/lock.png]" --
run 'regolith-sway-clamshell LID_CLOSE' 'wm.lidclose.action.power: LOCK' \
    'regolith.lockscreen.wallpaper.file: /nonexistent/lock.png'
expect 'lid close, LOCK: missing file' --
run 'regolith-sway-clamshell LID_CLOSE' 'wm.lidclose.action.power: LOCK' \
    'regolith.lockscreen.wallpaper.color.primary: #323A4C'
expect 'lid close, LOCK: the colour' '[--style]' "[$CSS]" --
run 'regolith-sway-clamshell LID_CLOSE' 'wm.lidclose.action.power: SLEEP' \
    "regolith.lockscreen.wallpaper.file: $SPACE"
expect 'lid close, SLEEP: locks first' '[-d]' '[--style]' "[$CSS]" '[--background]' "[$SPACE]" -- '[systemctl suspend]'

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
