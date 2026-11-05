#!/bin/bash
# Run regolith-screen-record against stand-ins for swaymsg, i3-msg, slurp,
# slop, pactl, notify-send, wf-recorder and ffmpeg, and check the recorder
# command lines, the file names, the notifications, and that the next key
# stops the recording. Also check that i3's and sway's 80_screen_recording
# bind the same three keys with the same resources and viewer labels. Run
# from the top of the source tree (debian/rules runs it at build time).
set -eu

SCRIPTS=$PWD/scripts
I3_PARTIAL=$PWD/usr/share/regolith/i3/config.d/80_screen_recording
SWAY_PARTIAL=$PWD/usr/share/regolith/sway/config.d/80_screen_recording
WORK=$(mktemp -d)
STATE=$WORK/run/regolith-screen-record/state
trap '[ -f "$STATE" ] && kill -KILL "$(head -n 1 "$STATE")" 2>/dev/null; rm -rf "$WORK"' EXIT
status=0

mkdir -p "$WORK/bin" "$WORK/home/.config" "$WORK/run"
# shellcheck disable=SC2016
echo 'XDG_VIDEOS_DIR="$HOME/My Videos"' > "$WORK/home/.config/user-dirs.dirs"

# The recorders: log the call, keep running, write the file on SIGINT.
# wf-recorder --help prints $STUB_WF_HELP.
cat > "$WORK/bin/wf-recorder" <<'STUB'
#!/usr/bin/env python3
import os, signal, sys, time
if sys.argv[1:] == ["--help"]:
    print(open(os.environ["STUB_WF_HELP"]).read())
    sys.exit(0)
with open(os.environ["STUB_LOG"], "a") as log:
    log.write("[%s %s]\n" % (os.path.basename(sys.argv[0]), " ".join(sys.argv[1:])))
def stop(*_):
    with open(sys.argv[-1], "w") as f:
        f.write("video")
    sys.exit(0)
signal.signal(signal.SIGINT, stop)
while True:
    time.sleep(0.05)
STUB
cp "$WORK/bin/wf-recorder" "$WORK/bin/ffmpeg"
# --help of wf-recorder 0.5 and later, 0.4, and 0.2 (excerpts)
cat > "$WORK/wf-help-0.5" <<'HELP'
  -a, --audio[=DEVICE]      Starts recording the screen with audio.
  --audio-backend           Specifies the audio backend among the available backends, for ex.
  -C, --audio-codec         Specifies the codec of the audio. These can be found by running:
  -P, --audio-codec-param   Change the audio codec parameters.
  -D, --no-damage           By default, wf-recorder will request a new frame from the compositor
  -y, --overwrite           Force overwriting the output file without prompting.
HELP
grep -vE -- '--(audio-backend|overwrite)' "$WORK/wf-help-0.5" > "$WORK/wf-help-0.4"
grep -vE -- '--(audio-codec|no-damage)' "$WORK/wf-help-0.4" > "$WORK/wf-help-0.2"
# swaymsg and i3-msg: one output to the right of another, $STUB_TREE as tree
for wm in swaymsg i3-msg; do
    cat > "$WORK/bin/$wm" <<'STUB'
#!/bin/sh
case "$2" in
    get_workspaces) echo '[{"focused":false,"output":"DP-1"},{"focused":true,"output":"DP-2"}]' ;;
    get_outputs) echo '[{"name":"DP-1","active":true,"rect":{"x":0,"y":0,"width":1920,"height":1080}},
        {"name":"DP-2","active":true,"rect":{"x":1920,"y":0,"width":1280,"height":720}}]' ;;
    get_tree) echo "$STUB_TREE" ;;
esac
STUB
done
# slurp and slop: print $STUB_SEL, or fail as when the selection is cancelled
for sel in slurp slop; do
    cat > "$WORK/bin/$sel" <<'STUB'
#!/bin/sh
echo "[${0##*/} $*]" >> "$STUB_LOG"
[ -n "$STUB_SEL" ] || exit 1
echo "$STUB_SEL"
STUB
done
# pactl: the default sink, or fail as without a sound server
cat > "$WORK/bin/pactl" <<'STUB'
#!/bin/sh
[ -n "$STUB_SINK" ] || exit 1
echo "$STUB_SINK"
STUB
cat > "$WORK/bin/notify-send" <<'STUB'
#!/bin/sh
echo "[notify-send $*]" >> "$STUB_LOG"
STUB
# date: a fixed time
printf '#!/bin/sh\necho "2026-11-05 10-20-30"\n' > "$WORK/bin/date"
chmod +x "$WORK/bin/"*

export STUB_LOG=$WORK/log STUB_WF_HELP=$WORK/wf-help-0.5 STUB_SEL='' STUB_SINK=alsa_output.pci.analog-stereo STUB_TREE='{}'
export PATH="$SCRIPTS:$WORK/bin:$PATH" HOME=$WORK/home XDG_RUNTIME_DIR=$WORK/run DISPLAY=:5
unset XDG_CONFIG_HOME

# run <args...>: run the helper; the exit status goes to the log
run() {
    : > "$STUB_LOG"
    local rc=0
    regolith-screen-record "$@" > /dev/null 2> "$WORK/err" || rc=$?
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

DIR="$WORK/home/My Videos"
FILE="$DIR/Screencast From 2026-11-05 10-20-30.mp4"
FILE1="$DIR/Screencast From 2026-11-05 10-20-30 (1).mp4"
NOTIFY="notify-send --app-name=Screen Recording --icon=media-record"
MONITOR="alsa_output.pci.analog-stereo.monitor"
WF="wf-recorder -D -y -c libx264 -x yuv420p -p preset=ultrafast"
FF="ffmpeg -nostdin -hide_banner -loglevel warning -y -f x11grab -framerate 30"
FF_OUT="-c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p"
FF_MP4="-movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 250000 -flush_packets 1 -f mp4"

run sway output
expect 'sway output: the focused output with desktop sound, notified' \
    "[$WF -o DP-2 --audio-backend=pulse --audio=$MONITOR -C aac -f $FILE]" \
    "[$NOTIFY Recording started Recording the screen with desktop sound to $FILE. Press a recording key again to stop.]" \
    'exit 0'

run sway area
expect 'sway, recording: any key stops it, notified with the file' \
    "[$NOTIFY Recording saved $FILE]" 'exit 0'
if [ "$(cat "$FILE" 2>/dev/null)" = video ] && [ ! -e "$STATE" ]; then
    echo "ok   sway, stopped: the file is complete"
else
    echo "FAIL sway, stopped: no complete file, or the recording is still marked running" >&2
    status=1
fi

run sway area
expect 'sway area, cancelled: nothing recorded' "[slurp -f %x %y %w %h]" 'exit 0'

# Older wf-recorder releases get only the options their --help lists
rm -f "$FILE"
STUB_WF_HELP=$WORK/wf-help-0.4 run sway output
expect 'sway output, wf-recorder 0.4: no -y or --audio-backend' \
    "[wf-recorder -D -c libx264 -x yuv420p -p preset=ultrafast -o DP-2 --audio=$MONITOR -C aac -f $FILE]" \
    "[$NOTIFY Recording started Recording the screen with desktop sound to $FILE. Press a recording key again to stop.]" \
    'exit 0'
run sway output
expect 'sway, wf-recorder 0.4, recording: the next key stops it' "[$NOTIFY Recording saved $FILE]" 'exit 0'
rm -f "$FILE"
STUB_WF_HELP=$WORK/wf-help-0.2 STUB_SEL="1930 10 401 301" run sway area
expect 'sway area, wf-recorder 0.2: no -D, -y, --audio-backend or -C' \
    "[slurp -f %x %y %w %h]" \
    "[wf-recorder -c libx264 -x yuv420p -p preset=ultrafast -g 1930,10 401x301 --audio=$MONITOR -f $FILE]" \
    "[$NOTIFY Recording started Recording the selected area with desktop sound to $FILE. Press a recording key again to stop.]" \
    'exit 0'
run sway output
expect 'sway, wf-recorder 0.2, recording: the next key stops it' "[$NOTIFY Recording saved $FILE]" 'exit 0'

STUB_SEL="10 20 301 201" STUB_SINK='' run i3 area
expect 'i3 area, no sound server: even size, no sound, a new file name' \
    "[slop -f %x %y %w %h]" \
    "[$FF -video_size 300x200 -i :5+10,20 $FF_OUT $FF_MP4 $FILE1]" \
    "[$NOTIFY Recording started Recording the selected area to $FILE1. Press a recording key again to stop.]" \
    'exit 0'
run i3 output
expect 'i3, recording: any key stops it' "[$NOTIFY Recording saved $FILE1]" 'exit 0'

rm -f "$FILE" "$FILE1"
STUB_TREE='{"nodes":[{"focused":false,"window":1},{"focused":true,"window":2,
    "rect":{"x":100,"y":50,"width":640,"height":480},
    "window_rect":{"x":2,"y":20,"width":636,"height":458}}]}' run i3 window
expect "i3 window: the focused window's content, with desktop sound" \
    "[$FF -video_size 636x458 -i :5+102,70 -f pulse -i $MONITOR $FF_OUT -c:a aac $FF_MP4 $FILE]" \
    "[$NOTIFY Recording started Recording the focused window with desktop sound to $FILE. Press a recording key again to stop.]" \
    'exit 0'

# A recorder that died is not taken for a running recording
kill -KILL "$(head -n 1 "$STATE")"
sleep 0.2
rm -f "$FILE"
run i3 output
expect 'i3 output, after the recorder died: a new recording of the focused output' \
    "[$FF -video_size 1280x720 -i :5+1920,0 -f pulse -i $MONITOR $FF_OUT -c:a aac $FF_MP4 $FILE]" \
    "[$NOTIFY Recording started Recording the screen with desktop sound to $FILE. Press a recording key again to stop.]" \
    'exit 0'
run i3 output
expect 'i3, recording: the next key stops it' "[$NOTIFY Recording saved $FILE]" 'exit 0'

run i3 everything
expect 'unknown mode: usage' 'exit 2'

# bindings <partial>: "<label> | <resource default line> | <key>" for each key
bindings() {
    awk '/^## /{label=$0} $1 == "set_from_resource" {res=$2" "$3" "$4}
        $1 == "bindsym" {print label " | " res " | " $2}' "$1"
}
if [ "$(bindings "$I3_PARTIAL")" = "$(bindings "$SWAY_PARTIAL")" ] &&
    [ "$(bindings "$I3_PARTIAL" | wc -l)" -eq 3 ]; then
    echo "ok   i3 and sway bind the same three keys, labels and resources"
else
    echo "FAIL i3 and sway recording keys differ:" >&2
    diff <(bindings "$SWAY_PARTIAL") <(bindings "$I3_PARTIAL") >&2 || true
    status=1
fi
# Each key runs the helper for its own session, for the output, an area and
# the window, in that order
cmds() {
    awk -v wm="$2" '$1 == "bindsym" {
        c = ""; for (i = 3; i <= NF; i++) c = c " " $i
        sub("^ exec --no-startup-id regolith-screen-record " wm " ", "", c); print c }' "$1"
}
if [ "$(cmds "$I3_PARTIAL" i3 | tr '\n' ' ')" = "output area window " ] &&
    [ "$(cmds "$SWAY_PARTIAL" sway | tr '\n' ' ')" = "output area window " ]; then
    echo "ok   each key runs regolith-screen-record for its session"
else
    echo "FAIL a key runs the wrong command:" >&2
    { cmds "$I3_PARTIAL" i3; cmds "$SWAY_PARTIAL" sway; } >&2
    status=1
fi

exit $status
