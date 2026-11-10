#!/bin/bash
# Run regolith-set-swaybg against stand-ins for trawlcat and swaymsg, and
# check the sway commands it sends. Run from the top of the source tree
# (debian/rules runs it at build time).
set -eu

SCRIPT=$PWD/scripts/regolith-set-swaybg
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
status=0

mkdir -p "$WORK/bin" "$WORK/run"
python3 -c 'import sys, base64; open(sys.argv[1], "wb").write(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))' "$WORK/wall.png"

# trawlcat <key> [default]: print the value from $STUB_RESOURCES
cat > "$WORK/bin/trawlcat" <<'EOF'
#!/bin/sh
value=$(sed -n "s/^$1:[[:space:]]*//p" "$STUB_RESOURCES" | tail -n 1)
if [ -n "$value" ]; then printf '%s\n' "$value"; elif [ "$#" -ge 2 ]; then printf '%s\n' "$2"; else exit 1; fi
EOF

# swaymsg -t get_outputs: print $STUB_OUTPUTS; swaymsg -t subscribe: write
# its PID to $WORK/subscribe.pid and return once the file $STUB_SWAY_EXIT
# exists, as when sway exits; swaymsg <command>: log it
cat > "$WORK/bin/swaymsg" <<'EOF'
#!/bin/sh
if [ "$1" = -t ] && [ "$2" = get_outputs ]; then
    printf '%s\n' "$STUB_OUTPUTS"
elif [ "$1" = -t ] && [ "$2" = subscribe ]; then
    echo $$ > "$WORK/subscribe.pid"
    while [ ! -e "$STUB_SWAY_EXIT" ]; do sleep 0.05; done
    echo '{ "change": "exit" }'
else
    printf "%s\n" "$*" | tr ";" "\n" >> "$STUB_LOG"
    echo '[ { "success": true } ]'
fi
EOF
# gsettings get <schema> <key>: print the value from $STUB_GSETTINGS (lines
# "<schema> <key> <value>"); gsettings monitor: report two changes
cat > "$WORK/bin/gsettings" <<'EOF'
#!/bin/sh
case $1 in
get)
    value=$(sed -n "s/^$2 $3 //p" "$STUB_GSETTINGS" | tail -n 1)
    [ -n "$value" ] || exit 1
    printf '%s\n' "$value" ;;
monitor)
    if [ -n "${STUB_MONITOR_HOLD-}" ]; then
        # one change, then keep running, as gsettings does, with the PID in
        # $STUB_MONITOR_HOLD
        echo $$ > "$STUB_MONITOR_HOLD"
        printf "%s: 'prefer-dark'\n" "$3"
        exec sleep 600
    fi
    printf "%s: 'prefer-dark'\n%s: 'default'\n" "$3" "$3" ;;
*)
    exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/trawlcat" "$WORK/bin/swaymsg" "$WORK/bin/gsettings"

# A few lines in the format of /usr/share/X11/rgb.txt
cat > "$WORK/rgb.txt" <<'EOF'
! $Xorg: rgb.txt,v 1.3 2000/08/17 19:54:00 cpqbld Exp $
255   0   0		red
 70 130 180		steel blue
 70 130 180		SteelBlue
190 190 190		gray
EOF

ONE_OUTPUT='[{"name":"Virtual-1","active":true,"scale":1.0,"rect":{"x":0,"y":0,"width":64,"height":40},"current_mode":{"width":64,"height":40}}]'
TWO_OUTPUTS='[{"name":"Virtual-1","active":true,"scale":1.0,"rect":{"x":0,"y":0,"width":64,"height":40},"current_mode":{"width":64,"height":40}},
 {"name":"HDMI-A-1","active":true,"scale":2.0,"rect":{"x":64,"y":0,"width":30,"height":20},"current_mode":{"width":60,"height":40}},
 {"name":"DP-1","active":false,"scale":1.0,"rect":{"x":0,"y":0,"width":0,"height":0},"current_mode":{"width":0,"height":0}}]'

export STUB_RESOURCES=$WORK/resources STUB_LOG=$WORK/log STUB_OUTPUTS=$ONE_OUTPUT
export STUB_GSETTINGS=$WORK/gsettings
: > "$STUB_GSETTINGS"
export REGOLITH_SWAYBG_RGB_TXT=$WORK/rgb.txt XDG_RUNTIME_DIR=$WORK/run HOME=$WORK
export WORK STUB_SWAY_EXIT=$WORK/sway-exited SWAYSOCK=$WORK/run/sway-ipc.1000.100.sock

# run <resources...>: run the script with these resources (and the arguments
# in SCRIPT_ARGS)
SCRIPT_ARGS=()
run() {
    printf '%s\n' "$@" > "$STUB_RESOURCES"
    : > "$STUB_LOG"
    PATH="$WORK/bin:$PATH" bash "$SCRIPT" "${SCRIPT_ARGS[@]}" > /dev/null 2> "$WORK/err" || echo "exit status $?" >> "$WORK/err"
}

# expect <description> <line>: the script sent this command
expect() {
    if grep -qxF -- "$2" "$STUB_LOG"; then
        echo "ok   $1"
    else
        echo "FAIL $1: no '$2' in:" >&2
        sed 's/^/       /' "$STUB_LOG" >&2
        status=1
    fi
}

# expect_none <description>: the script sent no command
expect_none() {
    if [ -s "$STUB_LOG" ]; then
        echo "FAIL $1: unexpected commands:" >&2
        sed 's/^/       /' "$STUB_LOG" >&2
        status=1
    else
        echo "ok   $1"
    fi
}

# expect_warning <description> <text>: the script printed this on stderr
expect_warning() {
    if grep -qF -- "$2" "$WORK/err"; then
        echo "ok   $1"
    else
        echo "FAIL $1: no '$2' on stderr:" >&2
        sed 's/^/       /' "$WORK/err" >&2
        status=1
    fi
}

# expect_pixels <description> <png> <x,y=#rrggbb>...: the image has these pixels
expect_pixels() {
    local desc=$1 png=$2; shift 2
    if python3 - "$png" "$@" <<'EOF'
import sys, zlib, struct
data = open(sys.argv[1], "rb").read()
pos, idat = 8, b""
while pos < len(data):
    n, tag = struct.unpack(">I4s", data[pos:pos + 8])
    body = data[pos + 8:pos + 8 + n]
    if tag == b"IHDR":
        w, h = struct.unpack(">II", body[:8])
    elif tag == b"IDAT":
        idat += body
    pos += 12 + n
raw = zlib.decompress(idat)
ok = True
for spec in sys.argv[2:]:
    xy, want = spec.split("=")
    if xy == "size":
        got = "%dx%d" % (w, h)
    else:
        x, y = (int(v) if int(v) >= 0 else (w if i == 0 else h) + int(v) for i, v in enumerate(xy.split(",")))
        o = y * (w * 3 + 1) + 1 + x * 3
        got = "#%02x%02x%02x" % tuple(raw[o:o + 3])
    if got != want:
        print("       %s: %s, expected %s" % (xy, got, want), file=sys.stderr)
        ok = False
sys.exit(0 if ok else 1)
EOF
    then
        echo "ok   $desc"
    else
        echo "FAIL $desc" >&2
        status=1
    fi
}

# Nothing set: the background is left alone
run 'regolith.wallpaper.file:' 'regolith.wallpaper.color.primary:'
expect_none 'empty file and colour: no command'
run 'regolith.wallpaper.color.secondary: #ffffff' 'regolith.wallpaper.color.shading.type: vertical'
expect_none 'only the secondary colour: no command'

# Colours in every form GNOME accepts
run 'regolith.wallpaper.color.primary: #102030'
expect '#rrggbb' 'output * background #102030 solid_color'
run 'regolith.wallpaper.color.primary: #ABC'
expect '#rgb' 'output * background #aabbcc solid_color'
run 'regolith.wallpaper.color.primary: #123456789'
expect '#rrrgggbbb' 'output * background #124578 solid_color'
run 'regolith.wallpaper.color.primary: #1234567890ab'
expect '#rrrrggggbbbb' 'output * background #125690 solid_color'
run 'regolith.wallpaper.color.primary: SteelBlue'
expect 'colour name' 'output * background #4682b4 solid_color'
run 'regolith.wallpaper.color.primary: Steel Blue'
expect 'colour name, other case and spaces' 'output * background #4682b4 solid_color'
run 'regolith.wallpaper.color.primary: rgb(255, 0, 50%)'
expect 'rgb()' 'output * background #ff0080 solid_color'
run 'regolith.wallpaper.color.primary: rgba(16,32,48,0.5)'
expect 'rgba()' 'output * background #102030 solid_color'
run 'regolith.wallpaper.color.primary: nosuchcolour'
expect 'unknown colour: black' 'output * background #000000 solid_color'
expect_warning 'unknown colour: warning' "not a colour: 'nosuchcolour'"

# An image, with the colour for the uncovered area
run "regolith.wallpaper.file: $WORK/wall.png" 'regolith.wallpaper.color.primary: red'
expect 'image + colour name' "output * background $WORK/wall.png fill #ff0000"
run "regolith.wallpaper.file: $WORK/wall.png"
expect 'image without colour' "output * background $WORK/wall.png fill #000000"
run 'regolith.wallpaper.file: ~/wall.png' 'regolith.wallpaper.color.primary: #102030'
expect 'image under ~' "output * background $WORK/wall.png fill #102030"

# A GNOME wallpaper XML file: the largest size, and the exact size per output
cat > "$WORK/wall.xml" <<EOF
<?xml version="1.0"?>
<!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">
<wallpapers>
  <wallpaper deleted="false">
    <name>Test</name>
    <size width="64" height="40">$WORK/small.png</size>
    <size width="128" height="80">$WORK/large.png</size>
  </wallpaper>
</wallpapers>
EOF
run "regolith.wallpaper.file: $WORK/wall.xml" 'regolith.wallpaper.color.primary: red'
expect 'XML: largest size on all outputs' "output * background $WORK/large.png fill #ff0000"
expect 'XML: exact size on the output' "output \"Virtual-1\" background $WORK/small.png fill #ff0000"

# A GNOME slideshow as Ubuntu ships it (<file>, no sizes): its first image
# while its start time is still to come (later on the picture follows the
# slideshow's clock)
cat > "$WORK/slideshow.xml" <<EOF
<background>
  <starttime>
    <year>2099</year><month>08</month><day>04</day>
    <hour>00</hour><minute>00</minute><second>00</second>
  </starttime>
  <static>
    <duration>1795.0</duration>
    <file>$WORK/first.png</file>
  </static>
  <transition>
    <duration>5.0</duration>
    <from>$WORK/first.png</from>
    <to>$WORK/second.png</to>
  </transition>
  <static>
    <duration>1795.0</duration>
    <file>$WORK/second.png</file>
  </static>
</background>
EOF
run "regolith.wallpaper.file: $WORK/slideshow.xml"
expect 'slideshow: first image' "output * background $WORK/first.png fill #000000"
printf '<background><starttime/></background>\n' > "$WORK/empty.xml"
run "regolith.wallpaper.file: $WORK/empty.xml" 'regolith.wallpaper.color.primary: red'
expect 'XML without an image: colour' 'output * background #ff0000 solid_color'
expect_warning 'XML without an image: warning' "no image in '$WORK/empty.xml'"

# An SVG image is XML, but not a wallpaper XML file: drawn as an image
cat > "$WORK/wall.svg" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="40" viewBox="0 0 64 40">
  <rect width="64" height="40" fill="#2e3440"/>
</svg>
EOF
run "regolith.wallpaper.file: $WORK/wall.svg" 'regolith.wallpaper.color.primary: red'
expect 'SVG image' "output * background $WORK/wall.svg fill #ff0000"

# Placement: regolith.wallpaper.mode, else GNOME's picture-options
run "regolith.wallpaper.file: $WORK/wall.png" 'regolith.wallpaper.options: centered'
expect 'options centered' "output * background $WORK/wall.png center #000000"
run "regolith.wallpaper.file: $WORK/wall.png" 'regolith.wallpaper.options: wallpaper'
expect 'options wallpaper' "output * background $WORK/wall.png tile #000000"
run "regolith.wallpaper.file: $WORK/wall.png" 'regolith.wallpaper.options: scaled'
expect 'options scaled' "output * background $WORK/wall.png fit #000000"
run "regolith.wallpaper.file: $WORK/wall.png" 'regolith.wallpaper.options: stretched'
expect 'options stretched' "output * background $WORK/wall.png stretch #000000"
run "regolith.wallpaper.file: $WORK/wall.png" 'regolith.wallpaper.options: zoom'
expect 'options zoom' "output * background $WORK/wall.png fill #000000"
run "regolith.wallpaper.file: $WORK/wall.png" 'regolith.wallpaper.options: centered' 'regolith.wallpaper.mode: tile'
expect 'mode wins over options' "output * background $WORK/wall.png tile #000000"
run "regolith.wallpaper.file: $WORK/wall.png" 'regolith.wallpaper.options: none' 'regolith.wallpaper.color.primary: red'
expect 'options none: colour only' 'output * background #ff0000 solid_color'

# A missing image: the colours instead
run 'regolith.wallpaper.file: /nonexistent/wall.png' 'regolith.wallpaper.color.primary: red'
expect 'missing image: colour' 'output * background #ff0000 solid_color'
expect_warning 'missing image: warning' "no such file: '/nonexistent/wall.png'"

# Gradients, one image per output in its own pixel size
run 'regolith.wallpaper.color.primary: red' 'regolith.wallpaper.color.secondary: #0000ff' \
    'regolith.wallpaper.color.shading.type: vertical'
V=$WORK/run/regolith-swaybg/gradient-vertical-ff0000-0000ff-64x40.png
expect 'vertical gradient: all outputs' "output * background $V fill #ff0000"
expect 'vertical gradient: output' "output \"Virtual-1\" background $V fill #ff0000"
expect_pixels 'vertical gradient: image' "$V" size=64x40 0,0=#ff0000 -1,0=#ff0000 0,-1=#0000ff -1,-1=#0000ff

run 'regolith.wallpaper.color.primary: red' 'regolith.wallpaper.color.secondary: #0000ff' \
    'regolith.wallpaper.color.shading.type: horizontal'
H=$WORK/run/regolith-swaybg/gradient-horizontal-ff0000-0000ff-64x40.png
expect 'horizontal gradient: output' "output \"Virtual-1\" background $H fill #ff0000"
expect_pixels 'horizontal gradient: image' "$H" size=64x40 0,0=#ff0000 0,-1=#ff0000 -1,0=#0000ff -1,-1=#0000ff
if [ -e "$V" ]; then
    echo "FAIL images of earlier settings are removed" >&2; status=1
else
    echo "ok   images of earlier settings are removed"
fi

STUB_OUTPUTS=$TWO_OUTPUTS run 'regolith.wallpaper.color.primary: #9A9996' \
    'regolith.wallpaper.color.secondary: #B8B8B8' 'regolith.wallpaper.color.shading.type: vertical'
A=$WORK/run/regolith-swaybg/gradient-vertical-9a9996-b8b8b8-64x40.png
B=$WORK/run/regolith-swaybg/gradient-vertical-9a9996-b8b8b8-60x40.png
expect 'two outputs: first' "output \"Virtual-1\" background $A fill #9a9996"
expect 'two outputs: second, scaled' "output \"HDMI-A-1\" background $B fill #9a9996"
expect_pixels 'two outputs: scaled image size' "$B" size=60x40 0,0=#9a9996 0,-1=#b8b8b8
if grep -q DP-1 "$STUB_LOG"; then
    echo "FAIL inactive output skipped" >&2; status=1
else
    echo "ok   inactive output skipped"
fi

run 'regolith.wallpaper.color.primary: red' 'regolith.wallpaper.color.secondary: #0000ff' \
    'regolith.wallpaper.color.shading.type: solid'
expect 'shading solid' 'output * background #ff0000 solid_color'
if ls "$WORK/run/regolith-swaybg/"*.png > /dev/null 2>&1; then
    echo "FAIL gradient images are removed when there is no gradient" >&2; status=1
else
    echo "ok   gradient images are removed when there is no gradient"
fi
run 'regolith.wallpaper.color.primary: red' 'regolith.wallpaper.color.shading.type: vertical'
expect 'gradient without secondary colour' 'output * background #ff0000 solid_color'
run "regolith.wallpaper.file: $WORK/wall.png" 'regolith.wallpaper.color.primary: red' \
    'regolith.wallpaper.color.secondary: #0000ff' 'regolith.wallpaper.color.shading.type: vertical'
expect 'image wins over gradient' "output * background $WORK/wall.png fill #ff0000"

# A Default/Dark pair chosen in Settings: the picture for the current style
cp "$WORK/wall.png" "$WORK/light.png"
cp "$WORK/wall.png" "$WORK/dark wall.png"
pair() { # pair <color-scheme>: the pair, and that style
    printf '%s\n' "org.gnome.desktop.background picture-uri 'file://$WORK/light.png'" \
        "org.gnome.desktop.background picture-uri-dark 'file://$WORK/dark%20wall.png'" \
        "org.gnome.desktop.interface color-scheme '$1'" > "$STUB_GSETTINGS"
}
pair default
run "regolith.wallpaper.file: $WORK/light.png"
expect 'pair, Default style: light picture' "output * background $WORK/light.png fill #000000"
run "regolith.wallpaper.file: $WORK/dark wall.png"
expect 'pair, dark picture set, Default style: light picture' "output * background $WORK/light.png fill #000000"
pair prefer-dark
run "regolith.wallpaper.file: $WORK/light.png"
expect 'pair, Dark style: dark picture' "output * background $WORK/dark\ wall.png fill #000000"
run 'regolith.wallpaper.file: ~/light.png'
expect 'pair, path under ~, Dark style: dark picture' "output * background $WORK/dark\ wall.png fill #000000"
run "regolith.wallpaper.file: $WORK/wall.png"
expect 'not a picture of the pair: drawn as it is' "output * background $WORK/wall.png fill #000000"
# The same picture for both styles, as a look sets it: drawn as it is
printf '%s\n' "org.gnome.desktop.background picture-uri 'file://$WORK/wall.png'" \
    "org.gnome.desktop.background picture-uri-dark 'file://$WORK/wall.png'" \
    "org.gnome.desktop.interface color-scheme 'prefer-dark'" > "$STUB_GSETTINGS"
run "regolith.wallpaper.file: $WORK/wall.png"
expect 'same picture for both styles' "output * background $WORK/wall.png fill #000000"
# --follow-style draws the background again on each style change
pair prefer-dark
SCRIPT_ARGS=(--follow-style)
run "regolith.wallpaper.file: $WORK/light.png"
SCRIPT_ARGS=()
if [ "$(grep -cxF "output * background $WORK/dark\ wall.png fill #000000" "$STUB_LOG")" = 2 ]; then
    echo "ok   --follow-style: drawn on each change"
else
    echo "FAIL --follow-style: drawn on each change:" >&2
    sed 's/^/       /' "$STUB_LOG" >&2
    status=1
fi
# check <description> <condition...>: report whether the condition holds
check() {
    local desc=$1; shift
    if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; status=1; fi
}
# Conditions, and waiting for them, used through check
# shellcheck disable=SC2317
{
# wait_for <seconds> <condition...>
wait_for() {
    local n=$(( $1 * 20 )); shift
    until "$@"; do n=$(( n - 1 )); [ "$n" -gt 0 ] || return 1; sleep 0.05; done
}
alive() { [ -s "$1" ] && kill -0 "$(cat "$1")" 2> /dev/null; }
dead() { ! alive "$1"; }
running() { kill -0 "$1" 2> /dev/null; }
ended() { ! running "$1"; }
drawn() { [ "$(grep -c . "$STUB_LOG")" -ge "$1" ]; }
no_lock() { ! compgen -G "$WORK/run/regolith-swaybg-follow-style.*" > /dev/null; }
}
check '--follow-style: no swaymsg left when the style changes stop' wait_for 2 dead "$WORK/subscribe.pid"
check '--follow-style: its lock is removed' wait_for 2 no_lock

# follow_style: start the watcher in the background; its PID is in $watcher
follow_style() {
    rm -f "$WORK/subscribe.pid"
    PATH="$WORK/bin:$PATH" bash "$SCRIPT" --follow-style > /dev/null 2>> "$WORK/err" &
    watcher=$!
}
: > "$STUB_LOG"
export STUB_MONITOR_HOLD=$WORK/monitor.pid
follow_style
first=$watcher
check '--follow-style: drawn on a change while sway runs' wait_for 3 drawn 1
check '--follow-style: waits for sway' wait_for 3 alive "$WORK/subscribe.pid"
# A second watcher for the same sway, as from a second exec: ends at once
follow_style
check '--follow-style: a second watcher for the same sway ends at once' wait_for 2 ended "$watcher"
check '--follow-style: the first watcher keeps running' running "$first"
# sway exits: the watcher, gsettings monitor and swaymsg end
touch "$STUB_SWAY_EXIT"
check '--follow-style: ends when sway exits' wait_for 3 ended "$first"
check '--follow-style: gsettings monitor ends with it' wait_for 2 dead "$STUB_MONITOR_HOLD"
check '--follow-style: swaymsg ends with it' wait_for 2 dead "$WORK/subscribe.pid"
# The next login, on the same user bus: a new sway gets its own watcher
rm -f "$STUB_SWAY_EXIT" "$STUB_MONITOR_HOLD"
: > "$STUB_LOG"
SWAYSOCK=$WORK/run/sway-ipc.1000.200.sock follow_style
check '--follow-style: the next sway gets a watcher' wait_for 3 drawn 1
touch "$STUB_SWAY_EXIT"
check '--follow-style: which ends with that sway' wait_for 3 ended "$watcher"
check '--follow-style: no gsettings monitor left' wait_for 2 dead "$STUB_MONITOR_HOLD"
unset STUB_MONITOR_HOLD
: > "$STUB_GSETTINGS"

exit $status
