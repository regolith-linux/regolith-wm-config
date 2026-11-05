#!/bin/bash
# Check regolith-i3-touchpad-gestures and i3's 61_touchpad_gestures:
# - the partial binds the same eight swipes as the sway session, with the same
#   Xresources and defaults, and passes each one to the helper;
# - the helper reads the bindings and picks the swipe direction as sway does;
# - with an X server at hand (Xvfb), the helper grabs swipes and a second
#   instance takes over from the first.
# Run from the top of the source tree (debian/rules runs it at build time).
set -eu

HELPER=$PWD/scripts/regolith-i3-touchpad-gestures
PARTIAL=$PWD/usr/share/regolith/i3/config.d/61_touchpad_gestures
status=0
fail() { echo "FAIL: $*"; status=1; }
pass() { echo "ok: $*"; }

# The sway session's defaults (regolith-sway-touchpad-gestures,
# 61_touchpad_guestures): gesture, resource, default command
expected='swipe:3:right three_right workspace prev_on_output
swipe:3:left three_left workspace next_on_output
swipe:3:up three_up exec ilia -p windows -t $ilia.stylesheet
swipe:3:down three_down exec ilia -p apps -t $ilia.stylesheet
swipe:4:right four_right move workspace to output right
swipe:4:left four_left move workspace to output left
swipe:4:up four_up move workspace to output up
swipe:4:down four_down move workspace to output down'

while read -r gesture name command; do
  line="set_from_resource \$wm.guesture.swipe.$name wm.guesture.swipe.$name $command"
  if grep -qxF "$line" "$PARTIAL"; then
    pass "$gesture defaults to '$command'"
  else
    fail "$PARTIAL lacks: $line"
  fi
  if grep -qF "'$gesture=\$wm.guesture.swipe.$name'" "$PARTIAL"; then
    pass "$gesture is passed to the helper"
  else
    fail "the exec_always line doesn't pass $gesture"
  fi
done <<< "$expected"

if grep -qF -- "--variable 'ilia.stylesheet=\$ilia.stylesheet'" "$PARTIAL"; then
  pass "the helper gets \$ilia.stylesheet to expand in the defaults"
else
  fail "the exec_always line doesn't pass \$ilia.stylesheet"
fi

n=$(grep -c '^exec_always --no-startup-id regolith-i3-touchpad-gestures' "$PARTIAL" || true)
[ "$n" = 1 ] && pass "one exec_always line" || fail "expected one exec_always line, found $n"

PYTHONDONTWRITEBYTECODE=1 python3 - "$HELPER" <<'PY' || status=1
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("gestures", sys.argv[1])
spec = importlib.util.spec_from_loader("gestures", loader)
g = importlib.util.module_from_spec(spec)
loader.exec_module(g)
bad = 0
def check(desc, got, want):
    global bad
    if got == want:
        print(f"ok: {desc}")
    else:
        print(f"FAIL: {desc}: got {got!r}, want {want!r}")
        bad = 1
check("parse a binding", g.parse_binding("swipe:3:left=workspace next_on_output"),
      ((3, "left"), "workspace next_on_output"))
check("keep '=' inside the command", g.parse_binding("swipe:4:up=exec foo --a=b"),
      ((4, "up"), "exec foo --a=b"))
check("an empty command is allowed (unbinds the swipe)", g.parse_binding("swipe:3:down="),
      ((3, "down"), ""))
for arg in ("pinch:3:left=x", "swipe:2:left=x", "swipe:3:sideways=x", "swipe:3:left", "swipe:x:left=x"):
    try:
        g.parse_binding(arg)
        check(f"reject {arg!r}", "accepted", "ValueError")
    except ValueError:
        check(f"reject {arg!r}", "ValueError", "ValueError")
check("read swipes and variables",
      g.parse_args(["--variable", "a=1", "--variable=ab=x=y", "swipe:3:up=exec ilia -t $ab"]),
      ({(3, "up"): "exec ilia -t $ab"}, {"a": "1", "ab": "x=y"}))
check("expand variables, longest name first",
      g.expand("exec ilia -p windows -t $ilia.stylesheet $ilia", {"ilia": "I", "ilia.stylesheet": "/s.css"}),
      "exec ilia -p windows -t /s.css I")
check("an empty variable expands to nothing", g.expand("-t $ilia.stylesheet", {"ilia.stylesheet": ""}), "-t ")
try:
    g.parse_args(["--variable", "novalue"])
    check("reject a variable without '='", "accepted", "ValueError")
except ValueError:
    check("reject a variable without '='", "ValueError", "ValueError")
# sway: the larger axis wins; ties go to the vertical axis
for dx, dy, want in ((-50, 3, "left"), (40, -39, "right"), (2, 30, "down"),
                     (-5, -6, "up"), (10, 10, "down"), (0, 0, None)):
    check(f"direction({dx}, {dy})", g.direction(dx, dy), want)
# the event structure matches libXi 1.8's XIGestureSwipeEvent on LP64
import ctypes
if ctypes.sizeof(ctypes.c_long) == 8:
    check("XIGestureSwipeEvent size", ctypes.sizeof(g.XIGestureSwipeEvent), 192)
    check("delta_x offset", g.XIGestureSwipeEvent.delta_x.offset, 120)
    check("flags offset", g.XIGestureSwipeEvent.flags.offset, 152)
    check("XGenericEventCookie size", ctypes.sizeof(g.XGenericEventCookie), 56)
sys.exit(bad)
PY

if command -v Xvfb > /dev/null; then
  work=$(mktemp -d)
  Xvfb :93 -nolisten tcp > "$work/xvfb.log" 2>&1 &
  xvfb=$!
  trap 'kill $xvfb $first $second 2> /dev/null; rm -rf "$work"' EXIT
  first='' second=''
  for _ in $(seq 50); do [ -e /tmp/.X11-unix/X93 ] && break; sleep 0.1; done
  DISPLAY=:93 "$HELPER" 'swipe:3:left=nop' 2> "$work/first.err" &
  first=$!
  sleep 1
  if kill -0 "$first" 2> /dev/null; then pass "the helper grabs swipes and keeps running"
  else fail "the helper exited: $(cat "$work/first.err")"; fi
  DISPLAY=:93 "$HELPER" 'swipe:3:left=nop' 2> "$work/second.err" &
  second=$!
  sleep 1.5
  if ! kill -0 "$first" 2> /dev/null && kill -0 "$second" 2> /dev/null; then
    pass "a second instance takes over from the first"
  else
    fail "takeover: first alive=$(kill -0 "$first" 2> /dev/null && echo y || echo n)," \
         "second alive=$(kill -0 "$second" 2> /dev/null && echo y || echo n): $(cat "$work/second.err")"
  fi
else
  echo "skip: no Xvfb, the grab and takeover are not checked"
fi

exit $status
