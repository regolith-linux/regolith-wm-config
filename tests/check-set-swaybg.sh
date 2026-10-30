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

# swaymsg -t get_outputs: print $STUB_OUTPUTS; swaymsg <command>: log it
cat > "$WORK/bin/swaymsg" <<'EOF'
#!/bin/sh
if [ "$1" = -t ] && [ "$2" = get_outputs ]; then
    printf '%s\n' "$STUB_OUTPUTS"
else
    printf "%s\n" "$*" | tr ";" "\n" >> "$STUB_LOG"
    echo '[ { "success": true } ]'
fi
EOF
chmod +x "$WORK/bin/trawlcat" "$WORK/bin/swaymsg"

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
export REGOLITH_SWAYBG_RGB_TXT=$WORK/rgb.txt XDG_RUNTIME_DIR=$WORK/run HOME=$WORK

# run <resources...>: run the script with these resources
run() {
    printf '%s\n' "$@" > "$STUB_RESOURCES"
    : > "$STUB_LOG"
    PATH="$WORK/bin:$PATH" bash "$SCRIPT" > /dev/null 2> "$WORK/err" || echo "exit status $?" >> "$WORK/err"
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

exit $status
